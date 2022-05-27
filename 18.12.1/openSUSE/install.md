wget http://downloads.asterisk.org/pub/telephony/asterisk/asterisk-18.12.1.tar.gz

sudo zypper install -t pattern devel_basis
sudo zypper in -y libedit-devel libxml2-devel xmlstarlet lua51-devel libcurl-devel libxslt-devel

./contrib/scripts/live_ast configure --with-jansson-bundled
./contrib/scripts/live_ast install
./contrib/scripts/live_ast run -fc

