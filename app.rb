require 'sinatra/base'
require 'json'
require 'mini_magick'
require 'celluloid/autostart'
require 'dotenv'
Dotenv.load

class ResizeJob
	include Celluloid
	def resize(file)
		puts "about to open #{file}.."
		image = MiniMagick::Image.open(file)		
		image.auto_orient
		image.resize('540x540^')
		image.gravity('center')
		image.crop('540x540!+0+0')
		output_name = "#{Dir.pwd}/tmp/600/#{file.split('/').last}.jpg" # oh my this is horrible
		puts "...STARTING to save #{file} as #{output_name}"				
		image.write(output_name)
		puts "...DONE saving #{file} as #{output_name}"
		return output_name
	end
end

class App < Sinatra::Base

	configure do
		set :server, :puma
		set :resize_pool, ResizeJob.pool(size: 6) # 3 would probably be fine.
	end

	get '/' do
		@photos = Dir.glob ENV['SOURCE_DIR']+ENV['SOURCE_GLOB']
		erb :index
	end

	get '/file/:filename' do
		content_type 'image/jpeg'
		File.read(ENV['SOURCE_DIR']+params['filename'].gsub('%20', ' '))
	end

	get '/output_file/:filename' do
		content_type 'image/jpeg'
		File.read("#{Dir.pwd}/tmp/output/#{params['filename']}")
	end

	get '/output/:filename' do
		@filename = params['filename']
		erb :output
	end

	get '/prints' do
		@files = Dir.glob("#{Dir.pwd}/tmp/output/*").reverse.map{|file| file.split('/').last }
		erb :output_list
	end

	post '/print/:filename' do
		`lp -d Dai_Nippon_Printing_DS_RX1 -o Cutter=2Inch -o PageSize=300dnp6x4 \"#{Dir.pwd}/tmp/output/#{params['filename']}\"`
		erb :printing
	end

	post '/build' do
		if params['files'].count != 3
			status 500
			"Must be exactly 3 files!"
		else
			output_filename = make_strip(params['files'])
			return "/output/#{output_filename.split("/").last}"
		end	
	end

	def make_strip(files)
		puts files
		image_futures = files.map{|file| 
			settings.resize_pool.future.resize(file)
		}
		puts "everyone's in the pool..."
		return generate_composite(image_futures.map{|future| future.value})
	end

	def generate_composite(files)
		output_file = "#{Dir.pwd}/tmp/output/#{Time.now.utc.to_i}.jpg"

		command = ["convert -size 1200x1800 xc:white"]		
		files.each_with_index do |file, index|
			command << "\"#{file}\" -geometry  +30+#{(index+1)*30 + index*540} -composite"
			command << "\"#{file}\" -geometry +630+#{(index+1)*30 + index*540} -composite"
		end
		command << "\"#{output_file}\""

		command_string = command.join(" ")
		puts "about to run command: #{command_string}"
		puts `#{command_string}`
		output_file
		
	end

end