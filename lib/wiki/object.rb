require 'sinatra/base'
require 'git'
require 'wiki/utils'
require 'wiki/extensions'

module Wiki
  PATH_PATTERN = '[\w.+\-_\/](?:[\w.+\-_\/ ]+[\w.+\-_\/])?'
  SHA_PATTERN = '[A-Fa-f0-9]{40}'

  class Object
    include Utils

    class NotFound < Sinatra::NotFound
      def initialize(path)
        super("#{path} not found", path)
      end
    end

    attr_reader :repo, :path, :commit, :object

    def self.find(repo, path, sha = nil)
      path ||= ''
      path = path.cleanpath
      forbid_invalid_path(path)
      commit = sha ? repo.gcommit(sha) : repo.log(1).path(path).first rescue nil
      return nil if !commit
      object = Object.git_find(repo, path, commit)
      return nil if !object 
      return Page.new(repo, path, object, commit, !sha) if object.blob?
      return Tree.new(repo, path, object, commit, !sha) if object.tree?
      nil
    end

    def self.find!(repo, path, sha = nil)
      find(repo, path, sha) || raise(NotFound.new(path))
    end

    def new?
      !@object
    end

    # Browsing current tree?
    def current?
      @current || new?
    end

    def history
      @history ||= @repo.log.path(path).to_a
    end

    def head_commit
      history.first
    end

    def prev_commit
      @prev_commit ||= @repo.log(2).object(@commit.sha).path(@path).to_a[1]
    end

    def next_commit
      h = history
      h.each_index { |i| return (i == 0 ? nil : h[i - 1]) if h[i].committer_date <= @commit.committer_date }
      h.last # FIXME. Does not work correctly if history is too short
    end
      
    def page?; self.class == Page; end
    def tree?; self.class == Tree; end

    def name
      return $1 if path =~ /\/([^\/]+)$/
      path
    end

    def pretty_name
      name.gsub(/\.([^.]+)$/, '')
    end

    def safe_name
      n = name
      n = 'root' if n.blank?
      n.gsub(/[^\w.\-_]/, '_')
    end

    def diff(to)
      @repo.diff(@commit.sha, to).path(path)
    end

    def initialize(repo, path, object = nil, commit = nil, current = false)
      path ||= ''
      path = path.cleanpath
      Object.forbid_invalid_path(path)
      @repo = repo
      @path = path.cleanpath
      @object = object
      @commit = commit
      @current = current
    end

    protected

    def self.forbid_invalid_path(path)
      forbid('Invalid path' => (!path.blank? && path !~ /^#{PATH_PATTERN}$/))
    end

    def self.git_find(repo, path, commit)
      return nil if !commit
      if path.blank?
        return commit.gtree rescue nil
      elsif path =~ /\//
        return path.split('/').inject(commit.gtree) { |t, x| t.children[x] } rescue nil
      else
        return commit.gtree.children[path] rescue nil
      end
    end

  end

  class Page < Object
    attr_writer :content

    def initialize(repo, path, object = nil, commit = nil, current = nil)
      super(repo, path, object, commit, current)
      @content = nil
    end

    def self.find(repo, path, sha = nil)
      object = super(repo, path, sha)
      object && object.page? ? object : nil
    end

    def content
      @content || current_content
    end

    def current_content
      @object ? @object.contents : nil
    end

    def write(content, message, author = nil)
      @content = content
      save(message, author)
    end    

    def save(message, author = nil)
      return if @content == current_content

      forbid('No content'   => @content.blank?,
             'Object already exists' => new? && Object.find(@repo, @path))

      repo.chdir {
        FileUtils.makedirs File.dirname(@path)
        File.open(@path, 'w') {|f| f << @content }
      }
      repo.add(@path)
      repo.commit(message.blank? ? '(Empty commit message)' : message, :author => author)

      @content = nil
      @prev_commit = @history = nil
      @commit = head_commit
      @object = Object.git_find(@repo, @path, @commit) || raise(NotFound.new(path))
      @current = true
    end

    def extension
      path =~ /.\.([^.]+)$/
      $1 || ''
    end

    def mime
      @mime ||= Mime.by_extension(extension) || Mime.new(App.config['default_mime'])
    end
  end
  
  class Tree < Object
    def initialize(repo, path, object = nil, commit = nil, current = false)
      super(repo, path, object, commit, current)
      @children = nil
    end
    
    def self.find(repo, path, sha = nil)
      object = super(repo, path, sha)
      object && object.tree? ? object : nil
    end

    def children
      @children ||= @object.trees.to_a.map {|x| Tree.new(repo, path/x[0], x[1], commit, current?)}.sort {|a,b| a.name <=> b.name } +
                    @object.blobs.to_a.map {|x| Page.new(repo, path/x[0], x[1], commit, current?)}.sort {|a,b| a.name <=> b.name }
    end

    def pretty_name
      '&radic;&macr; Root'/path
    end
  end
end