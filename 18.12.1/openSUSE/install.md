sudo zypper install -t pattern devel_basis  
sudo zypper in -y libedit-devel libxml2-devel xmlstarlet lua54-devel libcurl-devel libxslt-devel libopenssl-devel libsrtp-devel lua54-cjson lua54-luarocks patch libuuid-devel openldap2-devel  

sudo luarocks-5.4 install luasec  
sudo luarocks-5.4 install inspect  
sudo luarocks-5.4 install luasocket

