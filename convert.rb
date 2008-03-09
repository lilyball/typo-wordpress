#!/usr/bin/env ruby
require 'rubygems'
require 'sequel'
require 'logger'
require 'yaml'
require 'optparse'

class Object
  def try(name, *args)
    method(name).call *args
  end
end

class NilClass
  def try(name, *args)
    nil
  end
end

def wp_table(name)
  "#{$options[:prefix]}#{name}".to_sym
end

def yesno(prompt)
  while 1
    print "#{prompt} [yN] "
    answer = STDIN.gets.strip
    case answer
    when /^y/i:
      return true
    when /^n/i, "":
      return false
    end
  end
end

$options = {:prefix => "wp_", :ask => true, :overwrite => true}
opts = OptionParser.new do |opt|
  opt.banner = "Usage: convert.rb [options] from-db [to-db]"
  
  opt.separator ""
  
  opt.on("-p", "--prefix PREFIX", "Set the WordPress table prefix", "Default: wp_") do |p|
    $options[:prefix] = p
  end
  
  opt.separator ""
  
  opt.on("--[no-]overwrite", "Overwrite existing entries") do |o|
    $options[:overwrite] = o
    $options[:ask] = false
  end
  
  opt.on("--ask-overwrite", "Ask before overwriting existing entries", "[This is the default]") do
    $options[:ask] = true
  end
  
  opt.separator ""
  
  opt.on_tail("-h", "--help", "Show this message") do
    puts opt
    puts
    puts <<-EOF
from-db and to-db are URLs identifying a database.
Such a URL might look like mysql://username:password@host/blog

See the Sequel documentation for more information
EOF
    exit
  end
end

opts.parse!

if not (1..2).include?(ARGV.size)
  STDERR.puts "Unexpected number of arguments"
  STDERR.puts opts
  exit 1
end

FROM = Sequel.open ARGV[0]
TO = ARGV.size > 1 ? Sequel.open(ARGV[1]) : FROM

class Sequel::Database
  def last_insert_id
    self["SELECT LAST_INSERT_ID()"].first.values.first
  end
end

if not TO.table_exists?(wp_table(:terms))
  STDERR.puts "Error: I can't find the wordpress tables. Perhaps your prefix is wrong?"
  exit 1
end

puts "## Copying Categories"

categories = FROM[:categories].order(:position)
wp_terms = TO[wp_table(:terms)]
wp_term_taxonomy = TO[wp_table(:term_taxonomy)]
map_categories = {}

copy_term = proc do |name, slug, taxonomy|
  puts "Copying #{name} (#{slug})"
  term_id = wp_terms.filter(:slug => slug).first.try(:fetch, :term_id)
  if term_id.nil?
    wp_terms << {:name => name, :slug => slug}
    term_id = TO.last_insert_id
  end
  term_taxonomy_id = wp_term_taxonomy.filter(:term_id => term_id, :taxonomy => taxonomy).first.try(:fetch, :term_taxonomy_id)
  if term_taxonomy_id.nil?
    wp_term_taxonomy << {:term_id => term_id, :taxonomy => taxonomy}
    term_taxonomy_id = TO.last_insert_id
  end
  term_taxonomy_id
end

categories.all.each do |row|
  name = row[:name]
  slug = row[:permalink]
  term_taxonomy_id = copy_term.call(name, slug, "category")
  map_categories[row[:id]] = term_taxonomy_id
end

puts ""
puts "## Copying Tags"

tags = FROM[:tags]
map_tags = {}

tags.all.each do |row|
  name = row[:display_name]
  slug = row[:name]
  term_taxonomy_id = copy_term.call(name, slug, "post_tag")
  map_tags[row[:id]] = term_taxonomy_id
end

puts ""
puts "## Processing Text Filters"
text_filters = FROM[:text_filters]
map_text_filters = {}
MARKUP_MAP = {
  "textile" => "textile2"
}.freeze

text_filters.each do |row|
  markup = MARKUP_MAP.fetch(*[row[:markup]]*2)
  filter = (YAML.load(row[:filters]).first || "none").to_s
  puts "Found #{markup}, #{filter}"
  map_text_filters[row[:id]] = [markup, filter]
end

puts ""
puts "## Copying Pages"

pages = FROM[:contents].filter(:type => "Page")
wp_posts = TO[wp_table(:posts)]
wp_postmeta = TO[wp_table(:postmeta)]

pages.all.each do |row|
  title = row[:title]
  body = row[:body]
  created_at = row[:created_at]
  updated_at = row[:updated_at]
  # seems like Text-Control doesn't support per-page filters
  # text_filter = map_text_filters.fetch(row[:text_filter_id],["markdown","smartypants"])
  name = row[:name]
  published = row[:published] == 1
  
  post_status = published ? "publish" : "draft"
  
  puts "Copying #{title}"
  
  hash = {:post_author => 1, :post_date => created_at, :post_date_gmt => created_at + 4.hours,
          :post_content => body, :post_title => title, :post_status => post_status,
          :post_name => name, :post_modified => updated_at,
          :post_modified_gmt => updated_at + 4.hours, :post_type => "page"}
  existing = wp_posts.filter(:post_name => name, :post_type => "page")
  if existing.count == 1
    overwrite = $options[:ask] ? yesno("Post already exists, overwrite?") : $options[:overwrite]
    if overwrite
      wp_postmeta.filter(:post_id => existing.select(:ID)).delete
      existing.update(hash)
      post_id = existing.first[:ID]
    else
      puts "Skipping"
      next
    end
  elsif existing.count > 1
    STDERR.puts "Found more than 1 page with the same name"
    STDERR.puts "Ids: #{existing.map(:ID).join(", ")}"
    STDERR.puts "Aborting"
    exit 1
  else
    wp_posts << hash
    post_id = TO.last_insert_id
  end
  wp_postmeta << {:post_id => post_id, :meta_key => "_wp_page_template", :meta_value => "default"}
end

puts ""
puts "## Copying Articles"
articles = FROM[:contents].filter(:type => "Article")
articles_tags = FROM[:articles_tags]
categorizations = FROM[:categorizations]
wp_term_relationships = TO[wp_table(:term_relationships)]
map_articles = {}


make_relationship = proc do |object_id, term_taxonomy_id|
  wp_term_relationships << {:object_id => object_id,
                            :term_taxonomy_id => term_taxonomy_id}
  wp_term_taxonomy.filter(:term_taxonomy_id => term_taxonomy_id).update("count = count + 1")
end

articles.all.each do |row|
  title = row[:title]
  body = row[:body]
  extended = row[:extended]
  excerpt = row[:excerpt] || ""
  published_at = row[:published_at]
  updated_at = row[:updated_at]
  permalink = row[:permalink]
  guid = row[:guid]
  text_filter = map_text_filters.fetch(row[:text_filter_id],["markdown","smartypants"])
  published = row[:published] == 1
  allow_pings = row[:allow_pings] == 1
  allow_comments = row[:allow_comments] == 1
  
  post_date_hash = published ? {:post_date => published_at, :post_date_gmt => published_at + 4.hours} : {}
  post_content = extended.blank? ? body : "#{body}\n\n<!--more-->\n\n#{extended}"
  post_status = published ? "publish" : "draft"
  comment_status = allow_comments ? "open" : "closed"
  ping_status = allow_pings ? "open" : "closed"
  
  puts "Copying #{title}"
  
  hash = {:post_author => 1, :post_content => post_content, :post_title => title,
          :post_excerpt => excerpt, :post_status => post_status, :comment_status => comment_status,
          :ping_status => ping_status, :post_name => permalink,
          :post_modified => updated_at, :post_modified_gmt => updated_at + 4.hours,
          :guid => guid, :post_type => "post"}.merge(post_date_hash)
  existing = wp_posts.filter(:post_name => permalink, :post_type => "post")
  if existing.count == 1
    overwrite = $options[:ask] ? yesno("Article already exists, overwrite?") : $options[:overwrite]
    if overwrite
      wp_postmeta.filter(:post_id => existing.select(:ID)).delete
      existing.update(hash)
      post_id = existing.first[:ID]
    else
      puts "Skipping"
      next
    end
  elsif existing.count > 1
    STDERR.puts "Found more than 1 article with the same name"
    STDERR.puts "Ids: #{existing.map(:ID).join(", ")}"
    STDERR.puts "Aborting"
    exit 1
  else
    wp_posts << hash
    post_id = TO.last_insert_id
  end
  wp_postmeta << {:post_id => post_id, :meta_key => "_tc_post_format", :meta_value => text_filter[0]}
  wp_postmeta << {:post_id => post_id, :meta_key => "_tc_post_encoding", :meta_value => text_filter[1]}
  map_articles[row[:id]] = post_id
  
  # set up categorizations
  categorizations.filter(:article_id => row[:id]).all.each do |crow|
    make_relationship.call post_id, map_categories[crow[:category_id]]
  end
  
  # set up tags
  articles_tags.filter(:article_id => row[:id]).all.each do |trow|
    make_relationship.call post_id, map_tags[trow[:tag_id]]
  end
end

puts ""
puts "## Copying Comments"

comments = FROM[:feedback].filter(:type => "Comment")
wp_comments = TO[wp_table(:comments)]

comments.all.each_with_index do |row,idx|
  author = row[:author]
  body = row[:body]
  created_at = row[:created_at]
  user_id = row[:user_id] || 0
  article_id = row[:article_id]
  email = row[:email] || ""
  url = row[:url] || ""
  ip = row[:ip] || ""
  
  post_id = map_articles[article_id]
  
  puts "Copying comment #{idx}"
  
  wp_comments << {:comment_post_ID => post_id, :comment_author => author,
                  :comment_author_email => email, :comment_author_url => url,
                  :comment_author_IP => ip, :comment_date => created_at,
                  :comment_date_gmt => created_at + 4.hours, :comment_content => body,
                  :user_id => user_id}
end

puts ""
puts "## Copying Trackbacks"

trackbacks = FROM[:feedback].filter(:type => "Trackback")

trackbacks.all.each_with_index do |row,idx|
  title = row[:title]
  excerpt = row[:excerpt]
  created_at = row[:created_at]
  article_id = row[:article_id]
  url = row[:url]
  ip = row[:ip]
  blog_name = row[:blog_name]
  
  post_id = map_articles[article_id]
  
  puts "Copying trackback #{idx}"
  
  wp_comments << {:comment_post_ID => post_id, :comment_author => blog_name,
                  :comment_author_url => url, :comment_author_IP => ip,
                  :comment_date => created_at, :comment_date_gmt => created_at + 4.hours,
                  :comment_content => excerpt, :comment_type => "trackback"}
end
