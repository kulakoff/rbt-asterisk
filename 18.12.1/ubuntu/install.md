sudo apt install build-essential libedit-dev uuid-dev xmlstarlet libxml2-dev libsqlite3-dev libldap2-dev lua5.3 liblua5.3-dev libxslt1-dev libsrtp2-dev patch

wget https://luarocks.org/releases/luarocks-3.9.1.tar.gz
tar zxpf luarocks-3.9.1.tar.gz
cd luarocks-3.9.1
./configure && make && sudo make install

sudo luarocks install luasocket
sudo luarocks install luasec
sudo luarocks install inspect
sudo luarocks install lua-cjson 2.1.0-1
