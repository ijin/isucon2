require 'sinatra/base'
require 'slim'
require 'json'
require 'mysql2'
require 'resque'

class Isucon2App < Sinatra::Base
  $stdout.sync = true
  set :slim, :pretty => true, :layout => true

  helpers do
    def ensure_configured
      @config ||= nil

      return if @config

      @config = JSON.parse(IO.read(File.dirname(__FILE__) + "/../config/common.#{ ENV['ISUCON_ENV'] || 'local' }.json"))

      @mysql_connection = Mysql2::Client.new(
        :host => @config['database']['host'],
        :port => @config['database']['port'],
        :username => @config['database']['username'],
        :password => @config['database']['password'],
        :database => @config['database']['dbname'],
        :reconnect => true,
      )

      Resque.redis = @config['redis']

      @config
    end

    def connection
      ensure_configured
      @mysql_connection
    end

    # artists: id, name
    # order_requests: id, member_id
    # stocks: id, variation_id, seat_id, order_id, updated_at
    # ticket: id, name, artist_id
    # variation: id, name, ticket_id

    def r
      ensure_configured
      Resque.redis
    end

    def prepare_redis
      r.flushdb # delete everything

      artists_all_mysql.each do |artist|
        tickets = tickets_find_by_artist_id_mysql(artist["id"])

        tickets.each do |ticket|
          variations = variations_find_by_ticket_id_mysql(ticket["id"])

          variations.each do |variation|
            r.set("info:#{artist["id"]}:#{ticket["id"]}:#{variation["id"]}", "#{artist["name"]},#{ticket["name"]},#{variation["name"]}")

            orders = stocks_find_by_variation_id_mysql variation["id"]
            seats = orders.collect{|order|order["seat_id"]}.shuffle

            r.incrby("count:variations:#{variation["id"]}",seats.size)
            r.incrby("count:tickets:#{ticket["id"]}",seats.size)

            r.rpush("notbought:#{variation["id"]}", seats)
            r.rpush("all:#{variation["id"]}", seats)
          end
        end
      end
    end

    def recent_sold
      #[{"seat_id"=>"05-62", "v_name"=>"アリーナ席", "t_name"=>"西武ドームライブ", "a_name"=>"NHN48"}, ...]

      r.lrange("recent",0,9).collect do |element|
        seat_id, artist_name, ticket_name, variation_name = element.split(",")
        {"seat_id"=>seat_id, "v_name"=>variation_name, "t_name"=>ticket_name, "a_name"=>artist_name}
      end

      # recent_sold_mysql
    end

    def recent_sold_mysql
      mysql = connection
      mysql.query(
        'SELECT stock.seat_id, variation.name AS v_name, ticket.name AS t_name, artist.name AS a_name FROM stock
           JOIN variation ON stock.variation_id = variation.id
           JOIN ticket ON variation.ticket_id = ticket.id
           JOIN artist ON ticket.artist_id = artist.id
         WHERE order_id IS NOT NULL
         ORDER BY order_id DESC LIMIT 10',
      ).collect{|a|a}
    end

    def artists_all
      # [{"id"=>1, "name"=>"NHN48"}, {"id"=>2, "name"=>"はだいろクローバーZ"}]
      artists_all_mysql
    end

    def artists_all_mysql
      mysql = connection
      artists = mysql.query("SELECT * FROM artist ORDER BY id")
      artists.collect{|a|a}
    end

    def artists_find_by_id id
      # {"id"=>1, "name"=>"NHN48"}
      artists_find_by_id_mysql(id)
    end

    def artists_find_by_id_mysql id
      mysql = connection
      artist  = mysql.query(
        "SELECT id, name FROM artist WHERE id = #{ mysql.escape(params[:artistid]) } LIMIT 1",
      ).first
    end

    def tickets_find_by_artist_id artist_id
      # [{"id"=>1, "name"=>"西武ドームライブ"}, {"id"=>2, "name"=>"東京ドームライブ"}]
      tickets_find_by_artist_id_mysql(artist_id)
    end

    def tickets_find_by_artist_id_mysql artist_id
      mysql = connection
      tickets = mysql.query(
        "SELECT id, name FROM ticket WHERE artist_id = #{ mysql.escape(artist_id.to_s) } ORDER BY id",
      ).collect{|a|a}
    end

    def free_count_by_ticket_id ticket_id
      # 8189
      r.get("count:tickets:#{ticket_id}").to_i

      # free_count_by_ticket_id_mysql(ticket_id)
    end

    def free_count_by_ticket_id_mysql ticket_id
      mysql = connection
      mysql.query(
        "SELECT COUNT(*) AS cnt FROM variation
         INNER JOIN stock ON stock.variation_id = variation.id
         WHERE variation.ticket_id = #{ mysql.escape(ticket_id.to_s) } AND stock.order_id IS NULL",
      ).first["cnt"]
    end

    def free_count_by_variation_id variation_id
      # 4093
      r.get("count:variations:#{variation_id}").to_i

      # free_count_by_variation_id_mysql(variation_id)
    end

    def free_count_by_variation_id_mysql variation_id
      mysql = connection
      mysql.query(
        "SELECT COUNT(*) AS cnt FROM stock
         WHERE variation_id = #{ mysql.escape(variation_id.to_s) } AND order_id IS NULL",
      ).first["cnt"]
    end

    def tickets_find_by_id ticket_id # with artist name
      # {"id"=>1, "name"=>"西武ドームライブ", "artist_id"=>1, "artist_name"=>"NHN48"}
      tickets_find_by_id_mysql(ticket_id) # with artist name
    end

    def tickets_find_by_id_mysql ticket_id # with artist name
      mysql = connection
      ticket = mysql.query(
        "SELECT t.*, a.name AS artist_name FROM ticket t
         INNER JOIN artist a ON t.artist_id = a.id
         WHERE t.id = #{ mysql.escape(ticket_id) } LIMIT 1",
      ).first
    end

    def variations_find_by_ticket_id ticket_id
      # [{"id"=>1, "name"=>"アリーナ席"}, {"id"=>2, "name"=>"スタンド席"}]
      variations_find_by_ticket_id_mysql(ticket_id)
    end

    def variations_find_by_ticket_id_mysql ticket_id
      mysql = connection
      variations = mysql.query(
        "SELECT id, name FROM variation WHERE ticket_id = #{ mysql.escape(ticket_id.to_s) } ORDER BY id",
      ).collect{|a|a}
    end

    def stocks_find_by_variation_id variation_id
      # [{"seat_id"=>"00-00", "order_id"=>nil}, {"seat_id"=>"00-01", "order_id"=>3}, ..., , {"seat_id"=>"63-63", "order_id"=>nil}]

      # order id itself is not actually used. it only needs to be known, if the order was made
      all_seats = r.lrange("all:#{variation_id}",0,-1)
      notbought_seats = r.lrange("notbought:#{variation_id}",0,-1)

      seats = Hash[*all_seats.collect{|seat_id|[seat_id,:exists]}.flatten] # collect all seats
      notbought_seats.each{|seat_id|seats[seat_id]=nil} # delete not bought

      seats = seats.collect{|seat_id,order_id|{"seat_id" => seat_id, "order_id" => order_id}}

      # stocks_find_by_variation_id_mysql(variation_id)
    end

    def stocks_find_by_variation_id_mysql variation_id
      mysql = connection
      mysql.query(
        "SELECT seat_id, order_id FROM stock
         WHERE variation_id = #{ mysql.escape(variation_id.to_s) }",
      ).collect{|a|a}
    end

    def orders_all
      # [{"id"=>1, "member_id"=>"afds", "seat_id"=>"47-35", "variation_id"=>1, "updated_at"=>2012-11-03 05:28:51 +0900}, ...]

      r.keys("bought:*").collect do |key|
        x, variation_id, member_id, updated_at = key.split(":")
        updated_at = Time.at updated_at.to_i
  
        elements = r.lrange(key,0,-1)

        elements.collect do |seat_id|
          # needs persisting in order to get id.. not implemented yet
          {"id" => 0, "member_id" => member_id, "seat_id" => seat_id, "variation_id" => variation_id, "updated_at" => updated_at}
        end
      end.flatten
      # orders_all_mysql
    end

    def orders_all_mysql
      mysql = connection
      orders = mysql.query(
    
        'SELECT order_request.*, stock.seat_id, stock.variation_id, stock.updated_at
         FROM order_request JOIN stock ON order_request.id = stock.order_id
         ORDER BY order_request.id ASC',
      )
      orders.collect{|a|a}
    end

    # returns seat id or nil
    def buy member_id, variation_id
      # "31-16"

      seat_id = r.rpoplpush("notbought:#{variation_id}", "bought:#{variation_id}:#{member_id}:#{Time.now.to_i}")

      key = r.keys("info:*:*:#{variation_id}").first
      artist_name, ticket_name, variation_name = r.get(key).split(",")
      r.lpush("recent","#{seat_id},#{artist_name},#{ticket_name},#{variation_name}")

      r.decr("count:variations:#{variation_id}")
      r.decr("count:tickets:#{key.split(":")[1]}")

      seat_id

      # buy_mysql(member_id, variation_id)
    end

    def buy_mysql member_id, variation_id
      mysql = connection
      mysql.query('BEGIN')
      mysql.query("INSERT INTO order_request (member_id) VALUES ('#{ mysql.escape(member_id) }')")
      order_id = mysql.last_id
      mysql.query(
        "UPDATE stock SET order_id = #{ mysql.escape(order_id.to_s) }
         WHERE variation_id = #{ mysql.escape(variation_id) } AND order_id IS NULL
         ORDER BY RAND() LIMIT 1",
      )
      if mysql.affected_rows > 0
        seat_id = mysql.query(
          "SELECT seat_id FROM stock WHERE order_id = #{ mysql.escape(order_id.to_s) } LIMIT 1",
        ).first['seat_id']
        mysql.query('COMMIT')
        return seat_id
      else
        mysql.query('ROLLBACK')
        return nil
      end
    end
  end

  # main

  get '/' do
    slim :index, :locals => {
      :artists => artists_all,
    }
  end

  get '/artist/:artistid' do
    artist  = artists_find_by_id(params[:artistid])
    tickets = tickets_find_by_artist_id(artist['id'])
    tickets.each do |ticket|
      ticket["count"] = free_count_by_ticket_id(ticket['id'])
    end
    slim :artist, :locals => {
      :artist  => artist,
      :tickets => tickets,
    }
  end

  get '/ticket/:ticketid' do
    ticket = tickets_find_by_id(params[:ticketid])
    variations = variations_find_by_ticket_id ticket['id']

    variations.each do |variation|
      variation["count"] = free_count_by_variation_id(variation['id'])
      variation["stock"] = {}
      stocks_find_by_variation_id(variation['id']).each do |stock|
        variation["stock"][stock["seat_id"]] = stock["order_id"]
      end
    end
    slim :ticket, :locals => {
      :ticket     => ticket,
      :variations => variations,
    }
  end

  post '/buy' do
    seat_id = buy(params[:member_id], params[:variation_id])

    if seat_id
      slim :complete, :locals => { :seat_id => seat_id, :member_id => params[:member_id] }
    else
      slim :soldout
    end
  end


  get '/sidebar' do
    slim :sidebar, :layout => false
  end

  # admin

  get '/admin' do
    slim :admin
  end

  get '/admin/order.csv' do
    body  = ''
    orders = orders_all
    orders.each do |order|
      order['updated_at'] = order['updated_at'].strftime('%Y-%m-%d %X')
      body += order.values_at('id', 'member_id', 'seat_id', 'variation_id', 'updated_at').join(',')
      body += "\n"
    end
    [200, { 'Content-Type' => 'text/csv' }, body]
  end

  post '/admin' do
    mysql = connection
    open(File.dirname(__FILE__) + '/../config/database/initial_data.sql') do |file|
      file.each do |line|
        next unless line.strip!.length > 0
        mysql.query(line)
      end
    end

    prepare_redis

    redirect '/admin', 302
  end

  run! if app_file == $0
end
