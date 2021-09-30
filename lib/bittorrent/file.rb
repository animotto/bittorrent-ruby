# frozen_string_literal: true

require 'digest'

module BitTorrent
  ##
  # Torrent file
  class File
    PIECE_SIZE = 20
    DEFAULT_PIECE_LENGTH = 1024 * 256

    def initialize(file)
      @file = file
      @data = {
        'announce' => '',
        'creation date' => Time.now,
        'info' => {
          'piece length' => DEFAULT_PIECE_LENGTH,
          'pieces' => ''
        }
      }
      read
    end

    ##
    # Gets a value from metadata
    def [](key)
      @data[key]
    end

    ##
    # Sets a value to metadata
    def []=(key, value)
      @data[key] = value
    end

    ##
    # Returns metdata keys
    def keys
      @data.keys
    end

    ##
    # Returns encoded metadata
    def to_s
      Bencode.encode(@data)
    end

    ##
    # Returns announce address
    def announce
      @data['announce']
    end

    ##
    # Sets announce address
    def announce=(value)
      @data['announce'] = value
    end

    ##
    # Returns a comment
    def comment
      @data['comment']
    end

    ##
    # Sets comment
    def comment=(value)
      @data['comment'] = value
    end

    ##
    # Returns creation date
    def date
      Time.at(@data['creation date'])
    end

    def date=(value)
      value = value.to_i if value.instance_of?(Time)
      @data['creation date'] = value
    end

    ##
    # Returns piece length
    def piece_length
      @data['info']['piece length']
    end

    ##
    # Sets piece length
    def piece_length=(value)
      @data['info']['piece length'] = value
    end

    ##
    # Returns directory when torrent has multiple files
    def dir
      @data['info']['name']
    end

    ##
    # Sets a directory in torrent file that has multiple files
    def dir=(value)
      @data['info']['name'] = value if @data['info'].key?('files')
    end

    ##
    # Reads metadata from a file
    def read
      return unless ::File.exist?(@file)

      @data = Bencode.decode(::File.read(@file))
    end

    ##
    # Writes metadata to a file
    def write
      file = ::File.open(@file, 'w')
      file.write(Bencode.encode(@data))
      file.close
    end

    ##
    # Returns info hash
    def info_hash
      raise FileError, 'No info key in metadata' if @data['info'].nil?

      Digest::SHA1.digest(Bencode.encode(@data['info']))
    end

    ##
    # Returns a list of files
    def files
      list = []
      if @data['info'].key?('files')
        @data['info']['files'].each do |file|
          list << { 'name' => file['path'], 'length' => file['length'] }
        end
        return list
      end

      if @data['info'].key?('name') && @data['info'].key?('length')
        list << { 'name' => @data['info']['name'], 'length' => @data['info']['length'] }
      end
      list
    end

    ##
    # Returns a list of hashes of pieces
    def pieces
      list = []
      n = @data['info']['pieces'].bytesize / PIECE_SIZE
      n.times do |i|
        list << @data['info']['pieces'][(i * PIECE_SIZE)..(i * PIECE_SIZE + PIECE_SIZE - 1)]
      end
      list
    end

    ##
    # Adds a file to metadata
    def add_file(file)
      raise FileError, 'Piece length must be greater than 0' if @data['info']['piece length'] <= 0

      if @data['info'].key?('name') && @data['info'].key?('length')
        @data['info']['files'] = []
        @data['info']['files'] << {
          'path' => [@data['info']['name']],
          'length' => @data['info']['length']
        }
        @data['info'].delete('name')
        @data['info'].delete('length')
      end

      if @data['info'].key?('files')
        @data['info']['files'] << {
          'path' => file.split('/'),
          'length' => ::File.size(file)
        }
        @data['info']['pieces'] += hash_file(file, @data['info']['piece length'])
        return
      end

      @data['info']['name'] = ::File.basename(file)
      @data['info']['length'] = ::File.size(file)
      @data['info']['pieces'] = hash_file(file, @data['info']['piece length'])
    end

    ##
    # Removes a file from metadata
    def remove_file(file)
      if @data['info'].key?('files')
        pieces = String.new
        n = 0
        @data['info']['files'].each do |f|
          p = (f['length'] / @data['info']['piece length'].to_f).ceil
          if ::File.join(f['path']) != file
            s = n * PIECE_SIZE
            e = s + p * PIECE_SIZE - 1
            pieces << @data['info']['pieces'][s..e]
          end
          n += p
        end
        @data['info']['pieces'] = pieces
        @data['info']['files'].delete_if { |f| ::File.join(f['path']) == file }

        if @data['info']['files'].length == 1
          @data['info']['name'] = ::File.basename(::File.join(@data['info']['files'].first['path']))
          @data['info']['length'] = @data['info']['files'].first['length']
          @data['info'].delete('files')
        end
        return
      end

      return unless @data['info']['name'] == file

      @data['info'].delete('name')
      @data['info'].delete('length')
      @data['info'].pieces = String.new
    end

    private

    ##
    # Hashes a file and returns pieces
    def hash_file(name, length)
      pieces = String.new
      file = ::File.open(name, 'r')
      pieces << Digest::SHA1.digest(file.read(length)) until file.eof?
      file.close
      pieces
    end
  end

  class FileError < StandardError; end
end
