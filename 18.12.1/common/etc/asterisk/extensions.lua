package.path = "/opt/domophone/?.lua;/tmp/?.lua;/opt/domophone/lua/?.lua;"..package.path

key = '5251ce6649ef34e87e18e3bbbdceea27'

log = require 'log'
md5 = (require 'md5').sumhexa
luasql_mysql = require 'luasql.mysql'
inspect = require 'inspect'
http = require 'socket.http'
https = require 'ssl.https'

log.outfile = "/var/log/asterisk/pbx_lua.log"

-- Encodes a character as a percent encoded string
function char_to_pchar(c)
    return string.format("%%%02X", c:byte(1, 1))
end

-- encodeURI replaces all characters except the following with the appropriate UTF-8 escape sequences:
-- ; , / ? : @ & = + $
-- alphabetic, decimal digits, - _ . ! ~ * ' ( )
-- #
function encodeURI(str)
    return (str:gsub("[^%;%,%/%?%:%@%&%=%+%$%w%-%_%.%!%~%*%'%(%)%#]", char_to_pchar))
end

-- encodeURIComponent escapes all characters except the following: alphabetic, decimal digits, - _ . ! ~ * ' ( )
function encodeURIComponent(str)
    return (str:gsub("[^%w%-_%.%!%~%*%'%(%)]", char_to_pchar))
end

function mysql_connect()
    if not mysql_con then
        pcall(function ()
            mysql_con = luasql_mysql.mysql():connect("asterisk", "root", "qqq")
            mysql_con:execute("set names utf8mb4")
        end)
    end
end

function mysql_query(sql)
    mysql_connect()
    local qr = mysql_con:execute(sql)
    if not qr then
        log_debug("error in query: "..sql)
        return false
    end
    if type(qr) == "number" then
        return qr
    end
    if type(qr) == "userdata" then
        return qr:fetch({}, "a"), qr
    end
    log_debug("unknown result type ("..type(qr)..") from query ["..sql.."]")
end

function mysql_result(sql, default)
    local row = mysql_query(sql)
    if row then
        for k, v in pairs(row) do
            return v
        end
    else
        return default
    end
end

function log_debug(v)
    local l = channel.CDR("linkedid"):get()
    local u = channel.CDR("uniqueid"):get()
    local i
    if l ~= u then
        i = l..": "..u
    else
        i = u
    end
    local m = i..": "..inspect(v)
    log.debug(m)
    http.request("http://127.0.0.1:8081/pbx?msg="..encodeURIComponent(m))
end

function round(num, numDecimalPlaces)
    local mult = 10^(numDecimalPlaces or 0)
    return math.floor(num * mult + 0.5) / mult
end

function has_value(tab, val)
    for index, value in ipairs(tab) do
        if value == val then
            return true
        end
    end
    return false
end

function replace_char(str, pos, r)
    return str:sub(1, pos - 1) .. r .. str:sub(pos + 1)
end

function checkin()
    local src = channel.CALLERID("num"):get()
    if src.len == 10 then
        local prefix = tonumber(src.sub(1, 1))
        if prefix == 4 or prefix == 2 then
            log_debug("abnormal call: yes")
            app.busy()
        end
    end
end

function autoopen(flat_id, domophone_id)
    local ao1 = mysql_result("select count(*) from dm.autoopen where flat_id="..flat_id)
    local ao2 = mysql_result("select addtime(date, concat('00:', lpad(white_rabbit, 2, '0'), ':00')) > now() as autoopen from dm.flats left join dm.domophones using (domophone_id) left join dm.white_rabbit on domophones.ip=white_rabbit.domophone_ip and flat_number=apartment where white_rabbit and date is not null and flat_id="..flat_id)
    if (ao1 and tonumber(ao1) > 0) or (ao2 and tonumber(ao2) > 0) then
        log_debug("autoopen: yes")
        app.Wait(2)
        app.Answer()
        app.Wait(1)
        local dtmf = mysql_result("select dtmf from dm.domophones where domophone_id="..domophone_id)
        if not dtmf or dtmf == '' then
            dtmf = '1'
        end
        app.SendDTMF(dtmf, 25, 500)
        app.Wait(1)
        return true
    end
    log_debug("autoopen: no")
    return false
end

function blacklist(flat_id)
    if tonumber(mysql_result("select count(*) from dm.blacklist where flat_id="..flat_id)) > 0 then
        log_debug("blacklist: yes")
        app.Answer()
        app.Wait(2)
        app.Playback("ru/sorry")
        app.Playback("ru/feature-not-avail-line")
        app.Wait(1)
        return true
    end
    log_debug("blacklist: no")
    return false
end

function push(token, type, platform, extension, hash, caller_id, flat_id, dtmf, phone)
    local flat_number = mysql_result("select flat_number from dm.flats where flat_id = "..flat_id)
    if (phone) then
        log_debug("sending push for: "..extension.." ["..phone.."] ("..type..", "..platform..")")
        http.request("http://127.0.0.1:8082/push?token="..encodeURIComponent(token).."&type="..type.."&platform="..platform.."&extension="..extension.."&hash="..hash.."&caller_id="..encodeURIComponent(tostring(caller_id)).."&flat_id="..flat_id.."&dtmf="..encodeURIComponent(dtmf).."&phone="..phone.."&uniq="..channel.CDR("uniqueid"):get().."&flat_number="..flat_number)
    else
        log_debug("sending push for: "..extension.." ("..type..", "..platform..")")
        http.request("http://127.0.0.1:8082/push?token="..encodeURIComponent(token).."&type="..type.."&platform="..platform.."&extension="..extension.."&hash="..hash.."&caller_id="..encodeURIComponent(tostring(caller_id)).."&flat_id="..flat_id.."&dtmf="..encodeURIComponent(dtmf).."&uniq="..channel.CDR("uniqueid"):get().."&flat_number="..flat_number)
    end
end

function camshow(domophone_id)
    local hash = channel.HASH:get()

    if hash == nil then
        hash = md5(domophone_id..os.time())

        channel.HASH:set(hash)

        https.request{ url = "https://dm.lanta.me:443/sapi?key="..key.."&action=camshot&domophone_id="..domophone_id.."&hash="..hash }
        mysql_query("insert into dm.live (token, domophone_id, expire) values ('"..hash.."', '"..domophone_id.."', addtime(now(), '00:03:00'))")
    end

    return hash
end

function mobile_intercom(flat_id, domophone_id)
    local extension, res, caller_id
    local intercoms, qr = mysql_query("select token, type, platform, phone from dm.intercoms where flat_id="..flat_id)
    local dtmf = mysql_result("select dtmf from dm.domophones where domophone_id="..domophone_id)
    if not dtmf or dtmf == '' then
        dtmf = ''
    end
    local hash = camshow(domophone_id)
    caller_id = channel.CALLERID("name"):get()
    while intercoms do
        intercoms['phone'] = replace_char(intercoms['phone'], 1, '7')
        extension = tonumber(mysql_result("select dm.autoextension()")) + 2000000000
        mysql_query("insert into dm.turnusers_lt (realm, name, hmackey, expire) values ('dm.lanta.me', '"..extension.."', md5(concat('"..extension.."', ':', 'dm.lanta.me', ':', '"..hash.."')), addtime(now(), '00:03:00'))")
        mysql_query("insert into ps_aors (id, max_contacts, remove_existing, synchronized, expire) values ('"..extension.."', 1, 'yes', true, addtime(now(), '00:03:00'))")
        mysql_query("insert ignore into ps_auths (id, auth_type, password, username, synchronized) values ('"..extension.."', 'userpass', '"..hash.."', '"..extension.."', true)")
        mysql_query("insert ignore into ps_endpoints (id, auth, outbound_auth, aors, context, disallow, allow, dtmf_mode, rtp_symmetric, force_rport, rewrite_contact, direct_media, transport, ice_support, synchronized) values ('"..extension.."', '"..extension.."', '"..extension.."', '"..extension.."', 'default', 'all', 'opus,h264', 'rfc4733', 'yes', 'yes', 'yes', 'no', 'transport-tcp', 'yes', true)")
        mysql_query("delete from dm.voip_crutch where phone='"..intercoms['phone'].."'")
        if tonumber(intercoms['type']) == 3 then
            mysql_query("insert ignore into dm.voip_crutch (id, token, hash, platform, flat_id, dtmf, phone, expire) values ('"..extension.."', '"..intercoms['token'].."', '"..hash.."', '"..intercoms['platform'].."', '"..flat_id.."', '"..dtmf.."', '"..intercoms['phone'].."', addtime(now(), '00:01:00'))")
            intercoms['type'] = 0
        end
        push(intercoms['token'], intercoms['type'], intercoms['platform'], extension, hash, caller_id, flat_id, dtmf, intercoms['phone'])
        if not res then
            res = ""
        end
        res = res.."Local/"..extension
        intercoms = qr:fetch({}, "a")
        if intercoms then
            res = res.."&"
        end
    end
    return res
end

extensions = {

    [ "default" ] = {

        -- вызов с ПОДЪЕЗДНОГО (ОСНОВНОГО) домофона на специальный номер привязанный к квартире (на КМС уйдет "параллельный" звонок)
        [ "_1XXXXXXXXX" ] = function (context, extension)
            checkin()

            channel.MASTER:set("1")

            local flat_id = tonumber(extension:sub(2))
            local domophone = tonumber(channel.CALLERID("num"):get():sub(2))

            local hash

            log_debug("incoming ring from main panel "..domophone.." -> "..flat_id)

            local flat_number = mysql_result("select flat_number from dm.flats where flat_id = "..flat_id)
            channel.CALLERID("name"):set(channel.CALLERID("name"):get().." кв "..flat_number)

            local flat_ext = string.format("4%09d", flat_id)

            if not blacklist(flat_id) and not autoopen(flat_id, domophone) then
                local dest = ""
                local mi = mobile_intercom(flat_id, domophone)
                if mi then -- если есть мобильные SIP интерком(ы)
                    dest = dest.."&"..mi
                end
                local li = ""
                if flat_id and tonumber(mysql_result("select count(*) from ps_auths where id="..flat_ext)) > 0 then
                    li = channel.PJSIP_DIAL_CONTACTS(flat_ext):get()
                end
                if dest ~= "" then
                    if dest:sub(1, 1) == '&' then
                        dest = dest:sub(2)
                    end

                    log_debug("dialing: "..dest)

                    if hash then
                        app.Dial(dest, 120, "b(dm^hash^1("..hash.."))")
                    else
                        app.Dial(dest, 120)
                    end
                end
            end
            app.Hangup()
        end,

        -- вызов на мобильные SIP интерком(ы) (которых пока нет)
        [ "_2XXXXXXXXX" ] = function (context, extension)
            checkin()

            log_debug("starting loop for: "..extension)

            channel.MOBILE:set("1")
            local timeout = os.time() + 35
            local crutch = 1
            local intercom = mysql_query("select * from dm.voip_crutch where id='"..extension.."'")
            local status = ''
            local pjsip_extension = ''
            local skip = false
            while os.time() < timeout do
                pjsip_extension = channel.PJSIP_DIAL_CONTACTS(extension):get()
                if pjsip_extension ~= "" then
                    if not skip then
                        log_debug("has registration: "..extension)
                        skip = true
                    end
                    app.Dial(pjsip_extension, 35, "g")
                    status = channel.DIALSTATUS:get()
                    if status == "CHANUNAVAIL" then
                        log_debug(extension..': sleeping')
                        app.Wait(35)
                    end
                else
                    app.Wait(0.5)
                    if crutch % 10 == 0 and intercom then
                        push(intercom['token'], '0', intercom['platform'], extension, intercom['hash'], channel.CALLERID("name"):get(), intercom['flat_id'], intercom['dtmf'], intercom['phone']..'*')
                    end
                    crutch = crutch + 1
                end
            end
            app.Hangup()
        end,

        -- вызов на трубки домофонов
        [ "_3XXXXXXXXX" ] = function (context, extension)
            checkin()

            log_debug("flat intercom call")

            local flat_id = tonumber(extension:sub(2))
            local flat = mysql_query("select * from dm.flats where flat_id="..flat_id)

            if flat then
                log_debug(channel.CALLERID("num"):get().." >>> "..flat['flat_number'].."@"..string.format("1%05d", flat['domophone_id']))
                app.Dial("PJSIP/"..flat['flat_number'].."@"..string.format("1%05d", flat['domophone_id']), 120)
            end
            app.Hangup()
        end,

        -- вызов на стационарные интеркомы
        [ "_4XXXXXXXXX" ] = function (context, extension)
            checkin()

            log_debug("sip intercom call")

            local hash = channel.SHARED("HASH", "PJSIP/"..channel.CALLERID("num"):get()):get()

            app.Wait(2)
            channel.OCID:set(channel.CALLERID("num"):get())
            channel.CALLERID("all"):set('123456')
            log_debug("dialing: "..extension)

            if hash then
                app.Dial(channel.PJSIP_DIAL_CONTACTS(extension):get(), 120, "b(dm^hash^1("..hash.."))")
            else
                app.Dial(channel.PJSIP_DIAL_CONTACTS(extension):get(), 120)
            end
        end,

        -- вызов на мобильные интеркомы (приложение)
        [ "_5XXXXXXXXX" ] = function (context, extension)
            checkin()

            log_debug("mobile intercom test call")

            local flat_id = tonumber(extension:sub(2))
            local res
            local intercoms, qr = mysql_query("select token, type, platform, phone from dm.intercoms where flat_id="..flat_id)
            local dtmf = '1'
            local caller_id = 'LanTa'
            hash = md5(os.time())

            while intercoms do
                intercoms['phone'] = replace_char(intercoms['phone'], 1, '7')
                extension = tonumber(mysql_result("select dm.autoextension()")) + 2000000000
                mysql_query("insert into dm.turnusers_lt (realm, name, hmackey, expire) values ('dm.lanta.me', '"..extension.."', md5(concat('"..extension.."', ':', 'dm.lanta.me', ':', '"..hash.."')), addtime(now(), '00:03:00'))")
                mysql_query("insert into ps_aors (id, max_contacts, remove_existing, synchronized, expire) values ('"..extension.."', 1, 'yes', true, addtime(now(), '00:03:00'))")
                mysql_query("insert ignore into ps_auths (id, auth_type, password, username, synchronized) values ('"..extension.."', 'userpass', '"..hash.."', '"..extension.."', true)")
                mysql_query("insert ignore into ps_endpoints (id, auth, outbound_auth, aors, context, disallow, allow, dtmf_mode, rtp_symmetric, force_rport, rewrite_contact, direct_media, transport, ice_support, synchronized) values ('"..extension.."', '"..extension.."', '"..extension.."', '"..extension.."', 'default', 'all', 'opus,h264', 'rfc4733', 'yes', 'yes', 'yes', 'no', 'transport-tcp', 'yes', true)")
                mysql_query("delete from dm.voip_crutch where phone='"..intercoms['phone'].."'")
                if tonumber(intercoms['type']) == 3 then
                    mysql_query("insert ignore into dm.voip_crutch (id, token, hash, platform, flat_id, dtmf, phone, expire) values ('"..extension.."', '"..intercoms['token'].."', '"..hash.."', '"..intercoms['platform'].."', '"..flat_id.."', '"..dtmf.."', '"..intercoms['phone'].."', addtime(now(), '00:01:00'))")
                    intercoms['type'] = 0
                end
                app.wait(2)
                push(intercoms['token'], intercoms['type'], intercoms['platform'], extension, hash, caller_id, flat_id, dtmf, intercoms['phone'])
                if not res then
                    res = ""
                end
                res = res.."Local/"..extension
                intercoms = qr:fetch({}, "a")
                if intercoms then
                    res = res.."&"
                end
            end
            channel.CALLERID("name"):set(caller_id)
            if res then
                log_debug("dialing: "..res)
                app.Dial(res, 90)
            end
            app.Hangup()
        end,

        -- вызов на панель
        [ "_6XXXXXXXXX" ] = function (context, extension)
            checkin()

            log_debug("intercom test call "..string.format("1%05d", tonumber(extension:sub(2))))

            app.Dial("PJSIP/"..string.format("1%05d", tonumber(extension:sub(2))), 120)
            app.Hangup()
        end,

        -- 112
        [ "112" ] = function ()
            checkin()

            log_debug(channel.CALLERID("num"):get().." >>> 112")

--            app.Dial("PJSIP/112@lanta", 120)
--            app.Hangup()
            app.Answer()
            app.StartMusicOnHold()
            app.Wait(900)
        end,

        -- консъерж
        [ "9999" ] = function ()
            checkin()

            log_debug(channel.CALLERID("num"):get().." >>> 9999")

--            app.Dial("PJSIP/9999@lanta", 120)
--            app.Hangup()
            app.Answer()
            app.StartMusicOnHold()
            app.Wait(900)
        end,

        -- helpMe
        [ "429999" ] = function()
            checkin()

            log_debug(channel.CALLERID("num"):get().." >>> 429999")

            app.Dial("PJSIP/429999@lanta", 120, 'm')
            app.Hangup()
        end,

        -- открытие ворот по звонку
        [ "_x4752xxxxxx" ] = function (context, extension)
            checkin()

            log_debug("call2open: "..channel.CALLERID("num"):get().." >>> "..extension)

            local o = mysql_query("select domophone_id, door, ip from dm.openmap left join dm.domophones using (domophone_id) where src='"..channel.CALLERID("num"):get().."' and dst='"..extension.."'")
            if o then -- если это "телефон" открытия чего-либо
                log_debug("openmap: has match")
                mysql_query("insert into dm.door_open (date, ip, event, door, detail) values (now(), '"..o['ip'].."', 7, '"..o['door'].."', '"..channel.CALLERID("num"):get()..":"..extension.."')")
                https.request{ url = "https://dm.lanta.me:443/sapi?key="..key.."&action=open&domophone_id="..o['domophone_id'].."&door="..o['door'] }
            end
            app.Hangup()
        end,

        -- доп. панели и калитки
        [ "_X." ] = function (context, extension)
            checkin()

            log_debug("incomig ring "..channel.CALLERID("num"):get().." >>> "..extension)

            local g = tonumber(mysql_result("select count(*) from dm.gates where not poopphone and gate_domophone_id="..tonumber(channel.CALLERID("num"):get():sub(2))))
            if g > 0 then -- если вызов пришел с доп. домофона (калитка, ворота, доп. домофон в подъезде)
                channel.SLAVE:set("1")

                local domophone
                local flat
                local src_domophone = tonumber(channel.CALLERID("num"):get():sub(2))
                if extension:len() > 4 then -- несколько домов, есть префикс
                    flat = tonumber(extension:sub(5))
                    prefix = tonumber(extension:sub(1, 4))
                else -- один дом (или доп. домофон), без префикса
                    flat = tonumber(extension)
                    prefix = 0
                end
                domophone = tonumber(mysql_result("select entrance_domophone_id from dm.gates where gate_domophone_id="..src_domophone.." and prefix="..prefix.." and entrance_domophone_id in (select domophone_id from dm.flats where flat_number="..flat..")"))

                log_debug("dst domophone: "..domophone)

                channel.CALLERID("name"):set(channel.CALLERID("name"):get().." кв "..flat)

                if domophone then -- а вдруг?
                    local flat_id = mysql_result("select flat_id from dm.flats where flat_number="..tonumber(flat).." and domophone_id="..tonumber(domophone))
                    local hash
                    if flat_id and flat_id ~= "" then
                        log_debug("incoming ring from slave panel "..domophone.." -> "..flat_id)
                        if not blacklist(flat_id) and not autoopen(flat_id, src_domophone) then
                            -- вызов на КМС
                            local dest = "PJSIP/"..string.format("%d@1%05d", flat, domophone)
                            -- приложение (мобильный интерком)
                            local mi = mobile_intercom(flat_id, src_domophone)
                            -- стационарные SIP интеркомы
                            local flat_ext = string.format("4%09d", flat_id)
                            local li = ""
                            if flat_id and tonumber(mysql_result("select count(*) from ps_auths where id="..flat_ext)) > 0 then
                                li = channel.PJSIP_DIAL_CONTACTS(flat_ext):get()
                            end
                            if mi then -- если есть мобильные SIP интерком(ы)
                                dest = dest.."&"..mi
                            end
                            -- ебучий костыль, для ебучего офиса
                            if (flat_ext == "4000117453") or (li and li ~= "") then -- если есть стационарные SIP интерком(ы)
                                log_debug("has local intercom: "..flat_ext)
                                hash = camshow(domophone)
                                channel.SHARED("HASH"):set(hash)
                                dest = dest.."&Local/"..flat_ext.."/n"
                                http.request("http://127.0.0.1:8085/ffmpeg?domophone="..src_domophone.."&intercom="..flat_ext)
                            end
                            if dest:sub(1, 1) == '&' then
                                dest = dest:sub(2)
                            end

                            log_debug("dialing: "..dest)

                            if hash then
                                app.Dial(dest, 120, "b(dm^hash^1("..hash.."))")
                            else
                                app.Dial(dest, 120)
                            end
                        end
                    end
                end
            end
            app.Hangup()
        end,

        -- завершение вызова
        [ "h" ] = function (context, extension)
            local original_cid = channel.OCID:get()
            local src = channel.CDR("src"):get()
            if original_cid ~= nil then
                log_debug('reverting original CID: '..original_cid)
                channel.CALLERID("num"):set(original_cid)
                src = original_cid
            end

            local status = channel.DIALSTATUS:get()
            if status == nil then
                status = "UNKNOWN"
            end

            if channel.MOBILE:get() == "1" then
                log_debug("call ended: "..src.." >>> "..channel.CDR("dst"):get().." [mobile], channel status: "..status)
                return
            end

            if channel.MASTER:get() == "1" then
                log_debug("call ended: "..src.." >>> "..channel.CDR("dst"):get().." [master], channel status: "..status)
                return
            end

            if channel.SLAVE:get() == "1" then
                log_debug("call ended: "..src.." >>> "..channel.CDR("dst"):get().." [slave], channel status: "..status)
                return
            end

            log_debug("call ended: "..src.." >>> "..channel.CDR("dst"):get().." [other], channel status: "..status)
        end,
    },
}