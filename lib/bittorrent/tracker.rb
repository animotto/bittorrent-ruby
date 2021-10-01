# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'stringio'

module BitTorrent
  ##
  # Tracker
  class Tracker
    DEFAULT_PORT = 6881
    PEER_ID_LENGTH = 20
    PEER_ID_PREFIX = '-RB0001-'
    PEER_ID_ALPHABET =
      ('0'..'9').to_a +
      ('a'..'z').to_a

    attr_reader :peer_id

    def initialize(file)
      @file = file
      @announce_uri = URI(file.announce)
      unless @announce_uri.instance_of?(URI::HTTP) || @announce_uri.instance_of?(URI::HTTPS)
        raise TrackerError, "Unsupported announce URI scheme '#{@announce_uri.scheme}'"
      end

      @client = Net::HTTP.new(@announce_uri.host, @announce_uri.port)
      @client.use_ssl = @announce_uri.instance_of?(URI::HTTPS)

      @peer_id = generate_peer_id
    end

    ##
    # Announces to tracker and returns list of peers
    def announce(**args)
      query_uri = @announce_uri.dup
      query_uri.query = String.new if query_uri.query.nil?

      params = {
        info_hash: @file.info_hash,
        peer_id: @peer_id,
        port: args.fetch(:port, DEFAULT_PORT),
        downloaded: args.fetch(:downloaded, 0),
        uploaded: args.fetch(:uploaded, 0),
        left: args.fetch(:left, 0)
      }
      params[:ip] = args[:ip] if args.key?(:ip)
      params[:event] = args[:event] if args.key?(:event)
      params[:numwant] = args[:numwant] if args.key?(:numwant)
      params[:compact] = 1 if args[:compact]
      params[:no_peer_id] = 1 if args[:no_peer_id]

      query_uri.query = query_uri.query + URI.encode_www_form(params)
      response = @client.get(query_uri)
      unless response.is_a?(Net::HTTPSuccess)
        raise TrackerError, "The tracker responded with an HTTP error '#{response.code}'"
      end

      data = Bencode.decode(response.body)
      if data.key?('failure reason')
        raise TrackerError, "The tracker responded with an error '#{data['failure reason']}'"
      end

      data['peers'] = decompact_peers(data['peers']) if args[:compact]
      data
    end

    private

    ##
    # Generates peer ID
    def generate_peer_id
      n = PEER_ID_LENGTH - PEER_ID_PREFIX.bytesize
      PEER_ID_PREFIX + n.times.inject(String.new) { |m, _| m << PEER_ID_ALPHABET.sample }
    end

    ##
    # Decompacts peers
    def decompact_peers(peers)
      list = []
      buffer = StringIO.new(peers)
      until buffer.eof?
        ip = buffer.read(4).unpack('C4').join('.')
        port = buffer.read(2).unpack1('S>')
        list << { 'ip' => ip, 'port' => port }
      end
      list
    end
  end

  class TrackerError < RuntimeError; end
end
