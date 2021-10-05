# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'stringio'
require 'socket'

module BitTorrent
  ##
  # Tracker
  class Tracker
    class << self
      def build(file)
        announce_uri = URI(file.announce)
        tracker = TrackerBase.successors.detect { |t| t::SCHEMES.include?(announce_uri.scheme) }
        raise TrackerError, "Unsupported announce URI scheme '#{announce_uri.scheme}'" if tracker.nil?

        tracker.new(file)
      end
    end
  end

  ##
  # Tracker Base
  class TrackerBase
    DEFAULT_PORT = 6881
    PEER_ID_LENGTH = 20
    PEER_ID_PREFIX = '-RB0001-'
    PEER_ID_ALPHABET =
      ('0'..'9').to_a +
      ('a'..'z').to_a

    @@successors = []

    attr_reader :peer_id

    class << self
      def inherited(subclass)
        super
        @@successors << subclass
      end

      def successors
        @@successors
      end
    end

    def initialize(file)
      @file = file
      @announce_uri = URI(file.announce)
      @peer_id = generate_peer_id
    end

    def announce(**_args); end

    private

    ##
    # Generates peer ID
    def generate_peer_id
      n = PEER_ID_LENGTH - PEER_ID_PREFIX.bytesize
      PEER_ID_PREFIX + n.times.inject(String.new) { |m, _| m << PEER_ID_ALPHABET.sample }
    end
  end

  ##
  # Tracker HTTP/HTTPS
  class TrackerHTTP < TrackerBase
    SCHEMES = %w[http https].freeze

    def initialize(file)
      super
      @client = Net::HTTP.new(@announce_uri.host, @announce_uri.port)
      @client.use_ssl = @announce_uri.scheme == 'https'
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

      response = {
        peers: [],
        interval: data['interval'],
        leechers: data['complete'],
        seeders: data['incomplete']
      }
      data['peers'] = decompact_peers(data['peers']) if args[:compact]
      data['peers'].each do |peer|
        response[:peers] << TrackerPeer.new(peer['ip'], peer['port'], peer['peer id'])
      end

      TrackerResponse.new(**response)
    end

    private

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

  ##
  # Tracker UDP
  class TrackerUDP < TrackerBase
    SCHEMES = %w[udp].freeze

    ACTION_CONNECT_ID = 0
    ACTION_ANNOUNCE_ID = 1
    ACTION_ERROR_ID = 3
    CONNECT_MAGIC = 0x41727101980
    CONNECT_MIN_LENGTH = 16
    ANNOUNCE_MIN_LENGTH = 20

    RECEIVE_TIMEOUT = 5
    DGRAM_MAX_LENGTH = 1500

    EVENTS = {
      'none' => 0,
      'completed' => 1,
      'started' => 2,
      'stoped' => 3
    }.freeze

    def initialize(file)
      super
      @socket = UDPSocket.new
    end

    def announce(**args)
      connection_id = connect
      transaction_id = generate_transaction_id
      ip = 0
      ip = args[:ip].split('.').map(&:to_i).pack('C4').unpack('L>') unless args[:ip].nil?

      payload = [
        connection_id,
        ACTION_ANNOUNCE_ID,
        transaction_id,
        @file.info_hash,
        @peer_id,
        args.fetch(:downloaded, 0),
        args.fetch(:left, 0),
        args.fetch(:uploaded, 0),
        EVENTS.fetch(args.fetch(:event, 'none'), 'none'),
        ip,
        args.fetch(:key, 0),
        args.fetch(:num_want, -1),
        args.fetch(:port, DEFAULT_PORT)
      ].pack('Q>L>2a20a20Q>3L>3l>S>')
      send(payload)

      data = receive
      buffer = StringIO.new(data)
      action = buffer.read(4).unpack1('L>')
      transaction_id_response = buffer.read(4).unpack1('L>')
      raise TrackerError, 'Response transaction ID mismatch' if transaction_id_response != transaction_id

      if action == ACTION_ERROR_ID
        error = buffer.read.unpack1('Z*')
        raise TrackerError, "Response with the error: #{error}"
      end

      raise TrackerError, "Response action mismatch (#{action})" if action != ACTION_ANNOUNCE_ID
      raise TrackerError, "Response less than #{ANNOUNCE_MIN_LENGTH} bytes" if data.bytesize < ANNOUNCE_MIN_LENGTH
      raise TrackerError, 'Response has wrong length' if (data.bytesize - ANNOUNCE_MIN_LENGTH) % 6 != 0

      data = data.unpack('L>5a*')

      response = {
        peers: [],
        interval: data[2],
        leechers: data[3],
        seeders: data[4]
      }

      buffer = StringIO.new(data[5])
      until buffer.eof?
        ip = buffer.read(4).unpack('C4').join('.')
        port = buffer.read(2).unpack1('S>')
        response[:peers] << TrackerPeer.new(ip, port, nil)
      end

      TrackerResponse.new(**response)
    end

    private

    ##
    # Receives data from socket
    def receive(timeout: RECEIVE_TIMEOUT)
      raise TrackerError, 'Receiving timed out' unless @socket.wait_readable(timeout)

      data = @socket.recvfrom(DGRAM_MAX_LENGTH)
      raise TrackerError, 'Response IP address and port mismatch' if data[1] != @socket.peeraddr

      data[0]
    end

    ##
    # Sends data to socket
    def send(data)
      @socket.send(data, 0)
    end

    ##
    # Connects to the tracker and returns a connection ID
    def connect
      @socket.connect(@announce_uri.host, @announce_uri.port)
      transaction_id = generate_transaction_id
      payload = [
        CONNECT_MAGIC,
        ACTION_CONNECT_ID,
        transaction_id
      ].pack('Q>L>2')
      send(payload)

      data = receive
      raise TrackerError, "Response less than #{CONNECT_MIN_LENGTH} bytes" if data.bytesize < CONNECT_MIN_LENGTH

      data = data.unpack('L>2Q>')
      raise TrackerError, "Response action mismatch (#{data[0]})" if data[0] != ACTION_CONNECT_ID
      raise TrackerError, 'Response transaction ID mismatch' if data[1] != transaction_id

      data[2]
    end

    ##
    # Generates random transaction ID
    def generate_transaction_id
      rand(2**32)
    end
  end

  ##
  # Tracker response
  class TrackerResponse
    attr_reader :peers, :interval, :leechers, :seeders

    def initialize(**args)
      @peers = args.fetch(:peers, [])
      @interval = args.fetch(:interval, 0)
      @leechers = args.fetch(:leechers, 0)
      @seeders = args.fetch(:seeders, 0)
    end
  end

  ##
  # Tracker peer
  class TrackerPeer
    attr_reader :ip, :port, :peer_id

    def initialize(ip, port, peer_id)
      @ip = ip
      @port = port
      @peer_id = peer_id
    end

    def to_s
      return '' if @ip.nil? || @port.nil?

      "#{ip}:#{port}"
    end
  end

  ##
  # Tracker error exception
  class TrackerError < RuntimeError; end
end
