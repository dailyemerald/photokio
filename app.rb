require 'sinatra/base'
require 'sinatra-websocket'
require 'json'
require 'mini_magick'
require 'redis'
require 'celluloid/autostart'
require 'dotenv'
Dotenv.load

class ResizeJob
	include Celluloid
	def resize(file)
		redis = Redis.new

		after(5) { 
			redis.publish('log', "SLOW RESIZE: #{file}, terminating...")
			terminate 
		}

		redis.publish('log', "about to open #{file}..")
		image = MiniMagick::Image.open(ENV['SOURCE_DIR']+file)		
		image.auto_orient
		image.resize('500x500^')
		image.gravity('center')
		image.crop('500x500!+0+0')
		output_name = "#{ENV['RESIZE_DIR']}#{file}" # oh my this is horrible
		redis.publish('log', "...STARTING to save #{file} as #{output_name}")
		image.write(output_name)
		redis.publish('log', "...DONE saving #{file} as #{output_name}")
		return output_name
	end
end

class FileJob
	include Celluloid
	def initialize	
		Dir.mkdir(ENV['RESIZE_DIR']) rescue nil
		Dir.mkdir(ENV['OUTPUT_DIR']) rescue nil

		redis = Redis.new
		@resize_pool = ResizeJob.pool(size: 10)

		every(1) do		
			files = Dir.glob(ENV['SOURCE_DIR']+ENV['SOURCE_GLOB']).map{|file|
				file.split('/').last
			}.sort.reverse

			files.each do |file|
				if File.exists?("#{ENV['RESIZE_DIR']}#{file}")
					# cool, nothing to do. already have a square, resized frame for this.
				else
					if redis.get(file).nil?
						redis.setex(file, (3+2*rand()).to_i, 'hold') # it's like a lock
						future = @resize_pool.future.resize(file)
						redis.publish('log', "added #{file} to resize_pool")
					else
						# someone is currently resizing this. chill.
					end
				end
			end			
		end
	end
end

class App < Sinatra::Base

	configure do
		set :server, 'thin'
		set :sockets, []
		#set :resize_pool, ResizeJob.pool(size: 10)
		set :file_watcher, FileJob.new
		set :redis, Redis.new
		set :redis_listener, Thread.new {			
			redis = Redis.new
			redis.subscribe('log') { |on|				
				on.message { |chan, msg|					
					EM.next_tick { 
						settings.sockets.each{ |s| 
							s.send(msg) 
						} 
					}
				}				
			}			
		}
	end

	get '/ws' do
		if !request.websocket?
			redirect '/'
		else
			request.websocket do |ws|
				ws.onopen do
					ws.send("I'm from the server. This is a good sign.")
					settings.sockets << ws
				end
				ws.onclose do
					warn("wetbsocket closed")
					settings.sockets.delete(ws)
				end
			end
		end
	end

	def log(msg)		
		settings.redis.publish('log', msg)
	end

	get '/' do
		@photos = Dir.glob(ENV['RESIZE_DIR']+"*").reverse.map{|file| file.split('/').last }
		erb :index
	end

	get '/file/:filename' do
		content_type 'image/jpeg'
		File.read(ENV['RESIZE_DIR']+params['filename'].gsub('%20', ' '))
	end

	get '/output_file/:filename' do
		content_type 'image/jpeg'
		File.read("#{ENV['OUTPUT_DIR']}#{params['filename']}")
	end

	get '/output/:filename' do
		@filename = params['filename']
		erb :output
	end

	get '/prints' do
		@files = Dir.glob("#{ENV['RESIZE_DIR']}*").reverse.map{|file| file.split('/').last }
		erb :output_list
	end

	post '/print/:filename' do
		`lp -d Dai_Nippon_Printing_DS_RX1 -o Cutter=2Inch -o Finish=Matte -o PageSize=300dnp6x4 \"#{ENV['OUTPUT_DIR']}#{params['filename']}\"`
		erb :printing
	end

	post '/build' do
		if !params['files'].nil? and params['files'].count != 3
			status 500
			"Must be exactly 3 files!"
		else
			output_filename = make_strip(params['files'])
			return "/output/#{output_filename.split("/").last}"
		end	
	end

	get '/status' do
		erb :status
	end

	def make_strip(files)
		output_file = "#{ENV['OUTPUT_DIR']}#{Time.now.utc.to_i}.jpg"

		command = ["convert -size 1200x1800 xc:white"]		
		files.each_with_index do |file, index|
			puts index
			command << "\"#{ENV['RESIZE_DIR']+file}\" -geometry  +57+#{(index+1)*50 + index*500} -composite"
			command << "\"#{ENV['RESIZE_DIR']+file}\" -geometry +645+#{(index+1)*50 + index*500} -composite"
		end

		command << "\"./stamp.png\" -geometry  +13+1670 -composite"
		command << "\"./stamp.png\" -geometry +613+1670 -composite"

		command << "\"#{output_file}\""

		command_string = command.join(" ")
		log("about to run command: #{command_string}")
		puts `#{command_string}`
		output_file
	end

end