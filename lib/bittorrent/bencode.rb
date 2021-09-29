# frozen_string_literal: true

require 'stringio'

module BitTorrent
  ##
  # Bencoder
  class Bencode
    class << self
      ##
      # Encoder
      def encode(data)
        return encode_integer(data) if data.is_a?(Integer)
        return encode_string(data) if data.is_a?(String)
        return encode_list(data) if data.is_a?(Array)
        return encode_dictionary(data) if data.is_a?(Hash)

        raise BencodeError, "Unsupported data type #{data.class}"
      end

      ##
      # Decoder
      def decode(data)
        decode_data(StringIO.new(data))
      end

      private

      ##
      # Decodes data
      def decode_data(data)
        return if data.eof?

        char = data.readchar
        return decode_integer(data) if char == 'i'
        return decode_string(data) if char.between?('0', '9')
        return decode_list(data) if char == 'l'
        return decode_dictionary(data) if char == 'd'

        raise BencodeError, 'Invalid format'
      end

      ##
      # Encodes an integer
      def encode_integer(number)
        "i#{number}e"
      end

      ##
      # Decodes an integer
      def decode_integer(data)
        number = String.new
        char = String.new
        until data.eof?
          char = data.readchar
          break if char == 'e'

          number << char
        end

        raise BencodeError, 'Invalid integer format' if data.eof? && char != 'e'

        number.to_i
      end

      ##
      # Encodes a string
      def encode_string(string)
        "#{string.bytesize}:#{string}"
      end

      ##
      # Decodes a string
      def decode_string(data)
        length = String.new
        char = String.new
        data.seek(-1, IO::SEEK_CUR)
        until data.eof?
          char = data.readchar
          break if char == ':'

          length << char
        end

        raise BencodeError, 'Invalid string format' if data.eof? && char != ':'

        data.read(length.to_i)
      end

      ##
      # Encodes a list
      def encode_list(list)
        out = String.new
        list.each { |item| out << encode(item) }
        "l#{out}e"
      end

      ##
      # Decodes a list
      def decode_list(data)
        out = []
        until data.eof?
          char = data.readchar
          break if char == 'e'

          data.seek(-1, IO::SEEK_CUR)
          out << decode_data(data)
        end
        out
      end

      ##
      # Encodes a dictionary
      def encode_dictionary(dictionary)
        out = String.new
        dictionary = dictionary.sort_by { |k, _| k.to_s }
        dictionary.each { |item| out << encode_string(item[0].to_s) + encode(item[1]) }
        "d#{out}e"
      end

      ##
      # Decodes a dictionary
      def decode_dictionary(data)
        out = {}
        until data.eof?
          char = data.readchar
          break if char == 'e'

          out[decode_string(data)] = decode_data(data)
        end
        out
      end
    end
  end

  class BencodeError < RuntimeError; end
end
