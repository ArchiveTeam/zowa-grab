local urlparse = require("socket.url")
local http = require("socket.http")
local https = require("ssl.https")
local cjson = require("cjson")
local utf8 = require("utf8")

local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")
local concurrency = tonumber(os.getenv("concurrency"))
local item_type = nil
local item_name = nil
local item_value = nil
local item_user = nil

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false
local killgrab = false
local logged_response = false

local discovered_outlinks = {}
local discovered_items = {}
local bad_items = {}
local ids = {}

local thread_counts = {}

local retry_url = false
local is_initial_url = true

abort_item = function(item)
  abortgrab = true
  killgrab = true
  if not item then
    item = item_name
  end
  if not bad_items[item] then
    io.stdout:write("Aborting item " .. item .. ".\n")
    io.stdout:flush()
    bad_items[item] = true
  end
end

kill_grab = function(item)
  io.stdout:write("Aborting crawling.\n")
  killgrab = true
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

processed = function(url)
  if downloaded[url] or addedtolist[url] then
    return true
  end
  return false
end

discover_item = function(target, item)
  if not target[item] then
    local a, b = string.match(item, "^([^:]+):(.+)$")
    if a and b and a == "post" then
      discover_item(target, "post-api:" .. b)
    end
--print('discovered', item)
    target[item] = true
    return true
  end
  return false
end

find_item = function(url)
  local s, value = string.match(url, "^https?://(.-)([0-9]+)$")
  local type_ = nil
  if value then
    local types = {
      ["zowa.app/play/"]="play",
      ["zowa.app/rtist/"]="rtist",
      ["zowa.app/feature/"]="feature",
      ["zowa.app/search/result?tag="]="tag",
      ["zowa.app/audios/"]="audio",
      ["zowa.app/zch/threads/"]="thread",
      ["zowa.app/videos/"]="video"
    }
    type_ = types[s]
  else
    value = string.match(url, "^https?://([^/]*amazonaws%.com/.+)$")
    type_ = "url"
  end
  if value and type_ then
    return {
      ["value"]=value,
      ["type"]=type_
    }
  end
end

set_item = function(url)
  found = find_item(url)
  if found then
    item_type = found["type"]
    item_value = found["value"]
    item_name_new = item_type .. ":" .. item_value
    if item_name_new ~= item_name then
      ids = {}
      ids[item_value] = true
      abortgrab = false
      tries = 0
      retry_url = false
      is_initial_url = true
      item_name = item_name_new
      print("Archiving item " .. item_name)
    end
  end
end

allowed = function(url, parenturl)
  if ids[url]
    or ids[string.match(url, "^https?://(.*)$")]
    or (
      string.match(url, "^https?://cdn[^/]*zowa%.app/")
      and not item_type == "feature"
    )
    or string.match(url, "/play/[0-9]+%?list=[0-9]+$") then
    return true
  end

  if string.match(url, "^https?://cdn[^/]*zowa%.app/")
    and item_type == "feature" then
    return false
  end

  local found = false
  for pattern, type_ in pairs({
    ["^https?://([^/]*amazonaws%.com/.+)$"]="url"
  }) do
    match = string.match(url, pattern)
    if match then
      local new_item = type_ .. ":" .. match
      if new_item ~= item_name then
        discover_item(discovered_items, new_item)
        return false
      end
    end
  end

  if string.match(url, "^https?://[^/]*zowa.app/") then
    for _, pattern in pairs({
      "([0-9]+)"
    }) do
      for s in string.gmatch(string.match(url, "^https?://[^/]+(/.*)"), pattern) do
        if ids[string.lower(s)] then
          return true
        end
      end
    end
  end

  if not string.match(url, "^https?://[^/]*zowa%.app/") then
    discover_item(discovered_outlinks, url)
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  local html = urlpos["link_expect_html"]

  if allowed(url, parent["url"])
    and not processed(url)
    and string.match(url, "^https://")
    and not addedtolist[url] then
    addedtolist[url] = true
    return true
  end

  return false
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil
  
  downloaded[url] = true

  if abortgrab then
    return {}
  end

  local function decode_codepoint(newurl)
    newurl = string.gsub(
      newurl, "\\[uU]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])",
      function (s)
        return utf8.char(tonumber(s, 16))
      end
    )
    return newurl
  end

  local function fix_case(newurl)
    if not newurl then
      newurl = ""
    end
    if not string.match(newurl, "^https?://[^/]") then
      return newurl
    end
    if string.match(newurl, "^https?://[^/]+$") then
      newurl = newurl .. "/"
    end
    local a, b = string.match(newurl, "^(https?://[^/]+/)(.*)$")
    return string.lower(a) .. b
  end

  local function check(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    newurl = fix_case(newurl)
    local origurl = url
    if string.len(url) == 0 then
      return nil
    end
    local url = string.match(newurl, "^([^#]+)")
    local url_ = string.match(url, "^(.-)[%.\\]*$")
    while string.find(url_, "&amp;") do
      url_ = string.gsub(url_, "&amp;", "&")
    end
    if not processed(url_)
      and not processed(url_ .. "/")
      and allowed(url_, origurl) then
      if string.match(url_, "^https?://api%.zowa%.app/") then
        table.insert(urls, {
          url=url_,
          headers={
            ["Access-From"]="pwa"
          }
        })
      else
        table.insert(urls, {
          url=url_
        })
      end
      addedtolist[url_] = true
      addedtolist[url] = true
    end
  end

  local function checknewurl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^https?:////") then
      check(string.gsub(newurl, ":////", "://"))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^\\/\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (
      string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^data:")
      or string.match(newurl, "^irc:")
      or string.match(newurl, "^%${")
    ) then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function check_new_params(newurl, param, value)
    if string.match(newurl, "[%?&]" .. param .. "=") then
      newurl = string.gsub(newurl, "([%?&]" .. param .. "=)[^%?&;]+", "%1" .. value)
    else
      if string.match(newurl, "%?") then
        newurl = newurl .. "&"
      else
        newurl = newurl .. "?"
      end
      newurl = newurl .. param .. "=" .. value
    end
    check(newurl)
  end

  local function flatten_json(json)
    local result = ""
    for k, v in pairs(json) do
      result = result .. " " .. k
      local type_v = type(v)
      if type_v == "string" then
        v = string.gsub(v, "\\", "")
        result = result .. " " .. v .. ' "' .. v .. '"'
      elseif type_v == "table" then
        result = result .. " " .. flatten_json(v)
      end
    end
    return result
  end

  if allowed(url)
    and status_code < 300
    and not string.match(url, "^https?://[^/]*amazonaws%.com/")
    and not (
      string.match(url, "^https?://cdn[^/]*zowa%.app/")
      and not string.match(url, "%.m3u8$")
    ) then
    html = read_file(file)
    if string.match(url, "%.m3u8$") then
      for line in string.gmatch(html, "([^\n]+)") do
        if not string.match(line, "^#") then
          check(urlparse.absolute(url, line))
        end
      end
    end
    if item_type == "rtist" then
      check("https://api.zowa.app/api/v2/videos/pwa/users/" .. item_value .. "?sort=views_desc")
      check("https://api.zowa.app/api/v2/videos/pwa/users/" .. item_value .. "?sort=new")
      check("https://api.zowa.app/api/v2/users/" .. item_value .. "/total_like")
      check("https://api.zowa.app/api/v2/users/pwa/" .. item_value .. "/all_videos_count")
      check("https://api.zowa.app/api/v2/users/" .. item_value .. "/likes")
      check("https://api.zowa.app/api/v2/users/" .. item_value)
    end
    if item_type == "feature" then
      check("https://api.zowa.app/api/v2/videos/feature/" .. item_value)
    end
    if item_type == "play" then
      check("https://api.zowa.app/api/v2/videos/pwa/" .. item_value)
    end
    if item_type == "tag" then
      check("https://api.zowa.app/api/v2/tags/" .. item_value)
      -- credit for API use to yts98
      for _, duration in pairs({"&duration_start=30", "&duration_end=30", "&duration_end=10", ""}) do
        for _, voice_kinds in pairs({"1,2,0", "2,0", "1,0", "1,2", "0", "2", "1", ""}) do
          check("https://api.zowa.app/api/v2/videos/pwa?sort=new&tags=" .. item_value .. duration .. (string.len(voice_kinds) >= 1 and ("&voice_kinds=" .. voice_kinds) or ""))
        end
      end
    end
    if item_type == "thread" then
      check("https://api.zowa.app/api/v2/zch_threads/" .. item_value .. "?fields=zch_thread.user,zch_thread.comments,zch_thread.is_liked")
      for _, sort in pairs({"popular", "new", "old"}) do
        check("https://api.zowa.app/api/v2/zch_threads/" .. item_value .. "/comments?fields=zch_comment.is_liked,zch_comment.user&sort=" .. sort)
        check("https://api.zowa.app/api/v2/zch_threads/" .. item_value .. "/comments?fields=zch_comment.is_liked,zch_comment.user&sort=" .. sort .. "&limit=40")
      end
    end
    if string.match(url, "/comments%?fields=.+&limit=[0-9]+$") then
      local json = cjson.decode(html)
      local count = 0
      for _, d in pairs(json['data']) do
        count = count + 1
      end
      local base = string.match(url, "^https?://(.+)&limit=[0-9]+$")
      if thread_counts[base] ~= count then
        local limit = tonumber(string.match(url, "([0-9]+)$"))
        thread_counts[base] = count
        check_new_params(url, "limit", tostring(limit+20))
      end
    end
    if string.match(url, "/api/v2/videos/feature/") then
      local json = cjson.decode(html)
      check("https://api.zowa.app/api/v2/lists/show?list_id=" .. json["list_id"])
      for _, d in pairs(json["videos"]) do
        check("https://zowa.app/play/" .. d["id"] .. "?list=" .. json["list_id"])
      end
    end
    if string.match(url, "^https?://api%.zowa%.app/") then
      html = html .. flatten_json(cjson.decode(html))
    end
    for newurl in string.gmatch(string.gsub(html, "&quot;", '"'), '([^"]+)') do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
      checknewurl(newurl)
    end
    html = string.gsub(html, "&gt;", ">")
    html = string.gsub(html, "&lt;", "<")
    for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
      checknewurl(newurl)
    end
  end

  return urls
end

wget.callbacks.write_to_warc = function(url, http_stat)
  status_code = http_stat["statcode"]
  set_item(url["url"])
  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
  io.stdout:flush()
  logged_response = true
  if not item_name then
    error("No item name found.")
  end
  is_initial_url = false
  if string.match(url["url"], "^https?://api%.zowa%.app/") then
    local html = read_file(http_stat["local_file"])
    if not (
        string.match(html, "^%s*{")
        and string.match(html, "}%s*$")
      )
      and not (
        string.match(html, "^%s*%[")
        and string.match(html, "%]%s*$")
      ) then
      print("Did not get JSON data.")
      retry_url = true
      return false
    end
    local json = cjson.decode(html)
    -- do nothing, the above loading checked if this worked well
  end
  if http_stat["statcode"] ~= 200
    and http_stat["statcode"] ~= 404 then
    retry_url = true
    return false
  end
  if abortgrab then
    print("Not writing to WARC.")
    return false
  end
  retry_url = false
  tries = 0
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]
  
  if not logged_response then
    url_count = url_count + 1
    io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
    io.stdout:flush()
  end
  logged_response = false

  if killgrab then
    return wget.actions.ABORT
  end

  set_item(url["url"])
  if not item_name then
    error("No item name found.")
  end

  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if processed(newloc) or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end

  if abortgrab then
    abort_item()
    return wget.actions.EXIT
  end

  if status_code == 0 or retry_url then
    io.stdout:write("Server returned bad response. ")
    io.stdout:flush()
    tries = tries + 1
    local maxtries = 9
    if tries > maxtries then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    local sleep_time = math.random(
      math.floor(math.pow(2, tries-0.5)),
      math.floor(math.pow(2, tries))
    )
    io.stdout:write("Sleeping " .. sleep_time .. " seconds.\n")
    io.stdout:flush()
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  else
    downloaded[url["url"]] = true
  end

  tries = 0

  return wget.actions.NOTHING
end

wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  local function submit_backfeed(items, key)
    local tries = 0
    local maxtries = 5
    while tries < maxtries do
      if killgrab then
        return false
      end
      local body, code, headers, status = http.request(
        "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
        items .. "\0"
      )
      if code == 200 and body ~= nil and cjson.decode(body)["status_code"] == 200 then
        io.stdout:write(string.match(body, "^(.-)%s*$") .. "\n")
        io.stdout:flush()
        return nil
      end
      io.stdout:write("Failed to submit discovered URLs." .. tostring(code) .. tostring(body) .. "\n")
      io.stdout:flush()
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
    end
    kill_grab()
    error()
  end

  local file = io.open(item_dir .. "/" .. warc_file_base .. "_bad-items.txt", "w")
  for url, _ in pairs(bad_items) do
    file:write(url .. "\n")
  end
  file:close()
  for key, data in pairs({
    ["zowa-8kxeyhidzbbioqc3"] = discovered_items,
    ["urls-rqrgam65nl36pqp1"] = discovered_outlinks
  }) do
    print('queuing for', string.match(key, "^(.+)%-"))
    local items = nil
    local count = 0
    for item, _ in pairs(data) do
      print("found item", item)
      if items == nil then
        items = item
      else
        items = items .. "\0" .. item
      end
      count = count + 1
      if count == 100 then
        submit_backfeed(items, key)
        items = nil
        count = 0
      end
    end
    if items ~= nil then
      submit_backfeed(items, key)
    end
  end
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if killgrab then
    return wget.exits.IO_FAIL
  end
  if abortgrab then
    abort_item()
  end
  return exit_status
end


