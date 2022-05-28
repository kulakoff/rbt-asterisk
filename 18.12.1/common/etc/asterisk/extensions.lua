http = require 'socket.http'

function char_to_pchar(c)
   return string.format("%%%02X", c:byte(1, 1))
end

function encodeURI(str)
   return (str:gsub("[^%;%,%/%?%:%@%&%=%+%$%w%-%_%.%!%~%*%'%(%)%#]", char_to_pchar))
end

function encodeURIComponent(str)
   return (str:gsub("[^%w%-_%.%!%~%*%'%(%)]", char_to_pchar))
end

function push(ext, realm, from)
   http.request("http://127.0.0.1:8082/wakeup?ext="..encodeURIComponent(tostring(ext)).."&realm="..encodeURIComponent(tostring(realm)).."&from="..encodeURIComponent(tostring(from)))
end

extensions = {
   [ "default" ] = {

      [ "_XXXXX" ] = function (context, extension)
         app.progress()

         local timeout = os.time() + 60

         local pjsip_extension = ''

         push(extension, channel.CALLERID("name"):get(), channel.CALLERID("num"):get())

         while os.time() < timeout do
            pjsip_extension = channel.PJSIP_DIAL_CONTACTS(extension):get()
            if pjsip_extension ~= "" then
               app.Dial(pjsip_extension, 60, 'g')
               break
            else
               app.Wait(0.5)
            end
         end
      end,

   },
}
