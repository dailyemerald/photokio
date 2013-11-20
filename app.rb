require 'sinatra/base'
require 'sinatra-websocket'
require 'json'
require 'mini_magick'
require 'redis'
require 'celluloid/autostart'
#require 'logger'
require 'dotenv'
Dotenv.load

$redis = Redis.new

$stdout.reopen('photokio.log', 'w')
$stdout.sync = true
$stderr.reopen($stdout)

class ResizeJob
	include Celluloid

	def publish(obj)
		$redis.publish('log', obj.to_json)
	end

	def resize(file)
		$redis.setex(file, 5, 'hold') # it's like a lock.
		#puts "just set the hold for #{file}"
		image_size = 510

		publish({type: 'log', data: "about to open #{file}.."})

		image = MiniMagick::Image.open(ENV['SOURCE_DIR']+file)		
		image.auto_orient
		image.resize("#{image_size}x#{image_size}^")		

		#puts "img width: #{image[:width]}"
		x_offset = (1.0*image[:width] - image_size)/2.0
		x_offset = x_offset.to_i
		image.crop("#{image_size}x#{image_size}+#{x_offset}+0")
		
		output_name = "#{ENV['RESIZE_DIR']}#{file}" # oh my this is horrible
		#publish({type: 'log', data: "...STARTING to save #{file} as #{output_name}"})
		image.write(output_name)
		#puts "wrote #{output_name}"
		publish({type: 'log', data: "DONE resizing #{file}"})

		file = output_name.split("/").last
		publish({type: 'new-photo', data: file}) # FEELS FLIMSY
		
	end
end

class FileJob
	include Celluloid

	def publish(obj)
		$redis.publish('log', obj.to_json)
	end

	def initialize	
		puts `mkdir -p "#{ENV['SOURCE_DIR']}"` # put this somewhere else? or not a shell? TODO!
		puts `mkdir -p "#{ENV['RESIZE_DIR']}"` 
		puts `mkdir -p "#{ENV['OUTPUT_DIR']}"`

		every(1) do		

			#debug_pool = {      
			#	size: Celluloid::Actor[:resize_pool].size,
			#	busy_size: Celluloid::Actor[:resize_pool].busy_size,
			#	idle_size: Celluloid::Actor[:resize_pool].idle_size }.to_json
			#puts debug_pool

			files = Dir.glob(ENV['SOURCE_DIR']+ENV['SOURCE_GLOB']).map{|file|
				file.split('/').last
			}.sort.reverse

			files.each do |file|
				if File.exists?("#{ENV['RESIZE_DIR']}#{file}")
					# cool, nothing to do. already have a square, resized frame for this.
					#print "."
				else
					file_locked = $redis.get(file)
					#puts "#{file}, #{file_locked == nil}"
					if file_locked.nil?
						if Celluloid::Actor[:resize_pool].idle_size > 0											
							Celluloid::Actor[:resize_pool].async.resize(file)
							publish({type: 'log', data: "created ResizeJob for #{file}"})
							#print '!'
						else
							#print '%'
						end						
					else
						# someone is currently resizing this. chill.
						#print "_"
					end
				end
				
			end		
			#puts " "
			#puts Celluloid.stack_dump
			#puts "Actors left: #{Celluloid::Actor.all.to_set.length} Alive: #{(Celluloid::Actor.all.to_set.select &:alive?).length}"	
			
		end
	end
end

class App < Sinatra::Base

	configure do
		set :server, 'thin'
		set :sockets, []
		set :resize_pool, Celluloid::Actor[:resize_pool] = ResizeJob.pool(size: 4)
		set :file_watcher, FileJob.new

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
					#ws.send("I'm from the server. This is a good sign.")
					settings.sockets << ws
				end
				ws.onclose do
					#warn("wetbsocket closed")
					settings.sockets.delete(ws)
				end
			end
		end
	end

	def log(msg)		
		$redis.publish('log', {type: 'log', data: msg}.to_json)
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
		@files = Dir.glob("#{ENV['OUTPUT_DIR']}*").reverse.map{|file| file.split('/').last }
		erb :output_list
	end

	post '/print/:filename' do
		puts `lp -d Dai_Nippon_Printing_DS_RX1 -o Cutter=2Inch -o Finish=Matte -o PageSize=300dnp6x4 \"#{ENV['OUTPUT_DIR']}#{params['filename']}\"`
		redirect '/'
	end

	post '/build' do
		if params['files'].nil? or params['files'].count != 3
			status 500
			"Must be exactly 3 files!"
		else
			output_filename = make_strip(params['files'].reverse)
			return "/output/#{output_filename.split('/').last}"
		end	
	end

	get '/status' do
		erb :status
	end

	def make_strip(files)
		output_file = "#{ENV['OUTPUT_DIR']}#{Time.now.utc.to_i}.jpg"

		command = ["convert -size 1200x1800 xc:white"]		
		files.each_with_index do |file, index|			
			command << "\"#{ENV['RESIZE_DIR']+file}\" -geometry  +52+#{(index+1)*45 + index*500} -composite"
			command << "\"#{ENV['RESIZE_DIR']+file}\" -geometry +640+#{(index+1)*45 + index*500} -composite"
		end

		command << "\"./stamp.png\" -geometry   +8+1670 -composite"
		command << "\"./stamp.png\" -geometry +608+1670 -composite"

		command << "\"#{output_file}\""

		command_string = command.join(" ")
		log("about to run command: #{command_string}")
		puts `#{command_string}`
		output_file
	end

end
