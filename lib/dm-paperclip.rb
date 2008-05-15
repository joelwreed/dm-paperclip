# Paperclip allows file attachments that are stored in the filesystem. All graphical
# transformations are done using the Graphics/ImageMagick command line utilities and
# are stored in Tempfiles until the record is saved. Paperclip does not require a
# separate model for storing the attachment's information, instead adding a few simple
# columns to your table.
#
# Author:: Jon Yurek
# Copyright:: Copyright (c) 2008 thoughtbot, inc.
# License:: MIT License (http://www.opensource.org/licenses/mit-license.php)
#
# Paperclip defines an attachment as any file, though it makes special considerations
# for image files. You can declare that a model has an attached file with the
# +has_attached_file+ method:
#
#   class User < ActiveRecord::Base
#     has_attached_file :avatar, :styles => { :thumb => "100x100" }
#   end
#
#   user = User.new
#   user.avatar = params[:user][:avatar]
#   user.avatar.url
#   # => "/users/avatars/4/original_me.jpg"
#   user.avatar.url(:thumb)
#   # => "/users/avatars/4/thumb_me.jpg"
#
# See the +has_attached_file+ documentation for more details.

require 'tempfile'
require File.join(File.dirname(__FILE__), 'dm-paperclip', 'upfile')
require File.join(File.dirname(__FILE__), 'dm-paperclip', 'iostream')
require File.join(File.dirname(__FILE__), 'dm-paperclip', 'geometry')
require File.join(File.dirname(__FILE__), 'dm-paperclip', 'thumbnail')
require File.join(File.dirname(__FILE__), 'dm-paperclip', 'validations')
require File.join(File.dirname(__FILE__), 'dm-paperclip', 'storage')
require File.join(File.dirname(__FILE__), 'dm-paperclip', 'attachment')

module Paperclip
  VERSION = "2.1.0"
  class << self
    # Provides configurability to Paperclip. There are a number of options available, such as:
    # * whiny_thumbnails: Will raise an error if Paperclip cannot process thumbnails of 
    #   an uploaded image. Defaults to true.
    # * image_magick_path: Defines the path at which to find the +convert+ and +identify+ 
    #   programs if they are not visible to Rails the system's search path. Defaults to 
    #   nil, which uses the first executable found in the search path.
    def options
      @options ||= {
        :whiny_thumbnails  => true,
        :image_magick_path => nil
      }
    end

    def path_for_command command #:nodoc:
      path = [options[:image_magick_path], command].compact
      File.join(*path)
    end
  end

  class PaperclipError < StandardError #:nodoc:
  end

  class NotIdentifiedByImageMagickError < PaperclipError #:nodoc:
  end

  module Resource
    def self.included(base)
      base.extend Paperclip::ClassMethods
    end
  end

  module ClassMethods
    @@attachment_definitions = {}

    # +has_attached_file+ gives the class it is called on an attribute that maps to a file. This
    # is typically a file stored somewhere on the filesystem and has been uploaded by a user. 
    # The attribute returns a Paperclip::Attachment object which handles the management of
    # that file. The intent is to make the attachment as much like a normal attribute. The 
    # thumbnails will be created when the new file is assigned, but they will *not* be saved 
    # until +save+ is called on the record. Likewise, if the attribute is set to +nil+ is 
    # called on it, the attachment will *not* be deleted until +save+ is called. See the 
    # Paperclip::Attachment documentation for more specifics. There are a number of options 
    # you can set to change the behavior of a Paperclip attachment:
    # * +url+: The full URL of where the attachment is publically accessible. This can just
    #   as easily point to a directory served directly through Apache as it can to an action
    #   that can control permissions. You can specify the full domain and path, but usually
    #   just an absolute path is sufficient. The leading slash must be included manually for 
    #   absolute paths. The default value is "/:class/:attachment/:id/:style_:filename". See
    #   Paperclip::Attachment#interpolate for more information on variable interpolaton.
    #     :url => "/:attachment/:id/:style_:basename:extension"
    #     :url => "http://some.other.host/stuff/:class/:id_:extension"
    # * +default_url+: The URL that will be returned if there is no attachment assigned. 
    #   This field is interpolated just as the url is. The default value is 
    #   "/:class/:attachment/missing_:style.png"
    #     has_attached_file :avatar, :default_url => "/images/default_:style_avatar.png"
    #     User.new.avatar_url(:small) # => "/images/default_small_avatar.png"
    # * +styles+: A hash of thumbnail styles and their geometries. You can find more about 
    #   geometry strings at the ImageMagick website 
    #   (http://www.imagemagick.org/script/command-line-options.php#resize). Paperclip
    #   also adds the "#" option (e.g. "50x50#"), which will resize the image to fit maximally 
    #   inside the dimensions and then crop the rest off (weighted at the center). The 
    #   default value is to generate no thumbnails.
    # * +default_style+: The thumbnail style that will be used by default URLs. 
    #   Defaults to +original+.
    #     has_attached_file :avatar, :styles => { :normal => "100x100#" },
    #                       :default_style => :normal
    #     user.avatar.url # => "/avatars/23/normal_me.png"
    # * +path+: The location of the repository of attachments on disk. This can be coordinated
    #   with the value of the +url+ option to allow files to be saved into a place where Apache
    #   can serve them without hitting your app. Defaults to 
    #   ":merb_root/public/:class/:attachment/:id/:style_:filename". 
    #   By default this places the files in the app's public directory which can be served 
    #   directly. If you are using capistrano for deployment, a good idea would be to 
    #   make a symlink to the capistrano-created system directory from inside your app's 
    #   public directory.
    #   See Paperclip::Attachment#interpolate for more information on variable interpolaton.
    #     :path => "/var/app/attachments/:class/:id/:style/:filename"
    # * +whiny_thumbnails+: Will raise an error if Paperclip cannot process thumbnails of an
    #   uploaded image. This will ovrride the global setting for this attachment. 
    #   Defaults to true. 
    def has_attached_file name, options = {}
      include InstanceMethods

      @@attachment_definitions = {} if @@attachment_definitions.nil?
      @@attachment_definitions[name] = {:validations => []}.merge(options)
      
      property_options = options.delete_if { |k,v| ![ :public, :protected, :private, :accessor, :reader, :writer ].include?(key) }

      property "#{name}_file_name".to_sym, String, property_options
      property "#{name}_content_type".to_sym, String, property_options
      property "#{name}_file_size".to_sym, Integer, property_options

      after :save, :save_attached_files
      before :destroy, :destroy_attached_files

      define_method name do |*args|
        a = attachment_for(name)
        (args.length > 0) ? a.to_s(args.first) : a
      end

      define_method "#{name}=" do |file|
        attachment_for(name).assign(file)
      end

      define_method "#{name}?" do
        ! attachment_for(name).original_filename.blank?
      end
    end

    # Places ActiveRecord-style validations on the size of the file assigned. The
    # possible options are:
    # * +in+: a Range of bytes (i.e. +1..1.megabyte+),
    # * +less_than+: equivalent to :in => 0..options[:less_than]
    # * +greater_than+: equivalent to :in => options[:greater_than]..Infinity
    # * +message+: error message to display, use :min and :max as replacements
    #def validates_attachment_size(*fields)
    #  opts = opts_from_validator_args(fields)
    #  add_validator_to_context(opts, fields, Paperclip::Validate::SizeValidator)
    #end
    def validates_attachment_size name, options = {}
      @@attachment_definitions[name][:validations] << lambda do |attachment, instance|
        unless options[:greater_than].nil?
          options[:in] = (options[:greater_than]..(1/0)) # 1/0 => Infinity
        end
        unless options[:less_than].nil?
          options[:in] = (0..options[:less_than])
        end
        unless attachment.original_filename.blank? || options[:in].include?(instance.send(:"#{name}_file_size").to_i)
          min = options[:in].first
          max = options[:in].last
          
          if options[:message]
            options[:message].gsub(/:min/, min.to_s).gsub(/:max/, max.to_s)
          else
            "file size is not between #{min} and #{max} bytes."
          end
        end
      end
    end

    # Adds errors if thumbnail creation fails. The same as specifying :whiny_thumbnails => true.
    def validates_attachment_thumbnails name, options = {}
      @@attachment_definitions[name][:whiny_thumbnails] = true
    end

    # Places ActiveRecord-style validations on the presence of a file.
    #def validates_attachment_presence(*fields)
    #  opts = opts_from_validator_args(fields)
    #  add_validator_to_context(opts, fields, Paperclip::Validate::RequiredFieldValidator)
    #end
    def validates_attachment_presence name, options = {}
      @@attachment_definitions[name][:validations] << lambda do |attachment, instance|
        if attachment.original_filename.blank?
          options[:message] || "must be set."
        end
      end
    end
    
    # Places ActiveRecord-style validations on the content type of the file assigned. The
    # possible options are:
    # * +content_type+: Allowed content types.  Can be a single content type or an array.  Allows all by default.
    # * +message+: The message to display when the uploaded file has an invalid content type.
    #def validates_attachment_content_type(*fields)
    #  opts = opts_from_validator_args(fields)
    #  add_validator_to_context(opts, fields, Paperclip::Validate::ContentTypeValidator)
    #end
    def validates_attachment_content_type name, options = {}
      @@attachment_definitions[name][:validations] << lambda do |attachment, instance|
        valid_types = [options[:content_type]].flatten
        
        unless attachment.original_filename.nil?
          unless options[:content_type].blank?
            content_type = instance.send(:"#{name}_content_type")
            unless valid_types.any?{|t| t === content_type }
              options[:message] #|| ActiveRecord::Errors.default_error_messages[:inclusion]
            end
          end
        end
      end
    end

    # Returns the attachment definitions defined by each call to has_attached_file.
    def attachment_definitions
      @@attachment_definitions
    end

  end

  module InstanceMethods #:nodoc:
    def attachment_for name
      @attachments ||= {}
      @attachments[name] ||= Attachment.new(name, self, self.class.attachment_definitions[name])
    end
    
    def each_attachment
      self.class.attachment_definitions.each do |name, definition|
        yield(name, attachment_for(name))
      end
    end

    def save_attached_files
      each_attachment do |name, attachment|
        attachment.send(:save)
      end
    end

    def destroy_attached_files
      each_attachment do |name, attachment|
        attachment.queue_existing_for_delete
        attachment.flush_deletes
      end
    end
  end

end

# Set it all up.
if Object.const_defined?("ActiveRecord")
  ActiveRecord::Base.send(:include, Paperclip)
  File.send(:include, Paperclip::Upfile)
end