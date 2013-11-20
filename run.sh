# cp ./org.photokio.plist ~/Library/LaunchAgents
# launchctl load -w ~/Library/LaunchAgents/org.photokio.plist
cd /Users/emeraldphotobooth/photokio/
export PATH="/Users/emeraldphotobooth/.rbenv/shims:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
bundle exec rackup -E production -p 9000
