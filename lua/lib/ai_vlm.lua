--[[
    This file is part of darktable,
    copyright (c) 2026 Khairil Yusof.

    darktable is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    darktable is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with darktable.  If not, see <http://www.gnu.org/licenses/>.
]]

--[[
    ai_vlm
    Helper library for AI VLM (Vision-Language Model) API interactions.
    Generates captions from image analysis combined with film roll,
    capture time/date, geolocation, and user-provided context.

    USAGE
    * Include this file from your main lua script:
        local av = require "lib/ai_vlm"
    * Functions available:
        av.json_parse(string)             - Parse JSON string to Lua table
        av.encode_base64(string)          - Encode binary data to base64
        av.call_vlm(image_path, options)  - Call VLM API and return parsed result
        av.build_vlm_request(image_path, options) - Build and send request, return raw response
        av.parse_vlm_response(response)   - Parse VLM JSON response to {title, description}
        av.encode_image(image_path)       - Read and base64-encode an image file
        av.resize_image(image_path, max_dim) - Resize image to fit within max_dim pixels
        av.encode_image_resized(image_path, max_dim) - Resize and encode an image for VLM
        av.escape_json_string(str)        - Escape a string for use in JSON
        av.extract_json(str)              - Extract JSON object from freeform text
        av.resolve_image_path(path, obj)  - Resolve best image path (prefers JPEG in groups)
        av.lookup_place_name(lat, lon)    - Reverse geocode coordinates via OSM Nominatim
        av.format_datetime(dt_str)        - Format EXIF datetime to "Month Day, Year"
        av.extract_filmroll_context(str)  - Extract places/jobs/subjects from film roll name
]]

local dt = require "darktable"
local json = require "lib/json"

-- ---------------------------------------------------------------------------
-- JSON parser
-- ---------------------------------------------------------------------------

local function json_parse(s)
  local ok, result = pcall(json.decode, s)
  if ok then
    return result
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Base64 encoding
-- ---------------------------------------------------------------------------

local function encode_base64(data)
  local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local result = {}
  local len = #data
  local i = 1
  while i <= len - 2 do
    local c1, c2, c3 = string.byte(data, i, i + 2)
    local a1 = math.floor(c1 / 4)
    local a2 = (c1 % 4) * 16 + math.floor(c2 / 16)
    local a3 = (c2 % 16) * 4 + math.floor(c3 / 64)
    local a4 = c3 % 64
    result[#result + 1] = b:sub(a1 + 1, a1 + 1)
    result[#result + 1] = b:sub(a2 + 1, a2 + 1)
    result[#result + 1] = b:sub(a3 + 1, a3 + 1)
    result[#result + 1] = b:sub(a4 + 1, a4 + 1)
    i = i + 3
  end
  if i <= len then
    local c1 = string.byte(data, i)
    local a1 = math.floor(c1 / 4)
    local a2 = (c1 % 4) * 16
    if i + 1 <= len then
      local c2 = string.byte(data, i + 1)
      a2 = a2 + math.floor(c2 / 16)
      local a3 = (c2 % 16) * 4
      result[#result + 1] = b:sub(a1 + 1, a1 + 1)
      result[#result + 1] = b:sub(a2 + 1, a2 + 1)
      result[#result + 1] = b:sub(a3 + 1, a3 + 1)
      result[#result + 1] = "="
    else
      result[#result + 1] = b:sub(a1 + 1, a1 + 1)
      result[#result + 1] = b:sub(a2 + 1, a2 + 1)
      result[#result + 1] = "="
      result[#result + 1] = "="
    end
  end
  return table.concat(result)
end

-- ---------------------------------------------------------------------------
-- Image encoding
-- ---------------------------------------------------------------------------

local function encode_image(image_path)
  local f = io.open(image_path, "rb")
  if not f then
    return nil, "Cannot open image file: " .. image_path
  end
  local image_data = f:read("*a")
  f:close()
  return encode_base64(image_data), nil
end

-- ---------------------------------------------------------------------------
-- Image resizing for VLM
-- ---------------------------------------------------------------------------

local RAW_EXTENSIONS = {
  nef = true, cr2 = true, cr3 = true, arw = true, dng = true,
  orf = true, raf = true, pef = true, sr2 = true, sraw = true,
  ["3fr"] = true, fff = true, mos = true, mef = true,
  k25 = true, kdc = true, mrw = true, nrw = true,
  x3f = true, heic = true, heif = true,
}

local function is_raw_file(image_path, image_obj)
  if image_obj and image_obj.is_raw then
    return true
  end
  local ext = image_path:match("%.[^.]+$")
  if ext then
    return RAW_EXTENSIONS[string.lower(ext)] or false
  end
  return false
end

local function resize_image(image_path, max_dim, image_obj)
  max_dim = max_dim or 1024

  if image_obj then
    -- Use image object passed from caller (preferred method)
    local exporter = dt.new_format("jpeg")
    exporter.quality = 85
    exporter.max_height = 0
    exporter.max_width = 0
    exporter.max_dimension = max_dim

    local tmpfile = os.tmpname() .. ".jpg"
    local success, err = exporter:write_image(image_obj, tmpfile, false)
    if not success then
      return nil, "Image resize failed: " .. (err or "unknown error")
    end
    return tmpfile, nil
  end

  -- Try to get image from darktable gui
  if dt.gui.action_images and #dt.gui.action_images > 0 then
    local img = dt.gui.action_images[1]
    return resize_image(image_path, max_dim, img)
  end

  -- Try to load from file
  local img = dt.load_image(image_path)
  if img then
    return resize_image(image_path, max_dim, img)
  end
  
  return nil, "Image loading failed"
end

local function encode_image_resized(image_path, max_dim, image_obj)
  local resized_path, err = resize_image(image_path, max_dim, image_obj)
  if err then
    return nil, err
  end

  local encoded, err = encode_image(resized_path)
  if err then
    os.remove(resized_path)
    return nil, err
  end

  return encoded, resized_path
end

-- ---------------------------------------------------------------------------
-- JSON string escaping
-- ---------------------------------------------------------------------------

local function escape_json_string(str)
  return json.encode(str):sub(2, -2)
end

-- ---------------------------------------------------------------------------
-- JSON extraction from freeform text
-- ---------------------------------------------------------------------------

local function extract_json(str)
  str = str:gsub("^%s*```%w*\n?", ""):gsub("\n?```%s*$", "")

  local start_pos = str:find("{")
  local end_pos = str:find("}")
  if start_pos and end_pos and end_pos > start_pos then
    return str:sub(start_pos, end_pos)
  end
  return str
end

-- ---------------------------------------------------------------------------
-- VLM response parsing
-- ---------------------------------------------------------------------------

local function parse_vlm_response(response)
  local result = json_parse(response)

  if not result then
    return nil
  end

  if result.title and result.description then
    return { title = result.title, description = result.description }
  end

  local choices = result.choices
  if type(choices) == "table" and #choices > 0 then
    local message = choices[1].message
    if message and type(message) == "table" then
      local content = message.content
      if type(content) == "string" and content ~= "" then
        local json_str = extract_json(content)
        local parsed = json_parse(json_str)
        if parsed and parsed.title and parsed.description then
          return { title = parsed.title, description = parsed.description }
        end
      end
    end
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- Film roll context extraction
-- ---------------------------------------------------------------------------

local function extract_filmroll_context(filmroll)
  if not filmroll or filmroll == "" then
    return nil
  end

  local parts = {}
  for part in filmroll:gmatch("[^%-/]+") do
    local trimmed = part:match("^%s*(.-)%s*$")
    if #trimmed > 0 then
      parts[#parts + 1] = trimmed
    end
  end

  local meaningful = {}
  local date_pattern = "^%d%d%d%d[%-]?%d%d[%-]?%d%d$"

  for _, part in ipairs(parts) do
    if part:match(date_pattern) then
      goto continue
    end
    if #part > 2 then
      meaningful[#meaningful + 1] = part
    end
    ::continue::
  end

  if #meaningful > 0 then
    return table.concat(meaningful, ", ")
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- Datetime formatting
-- ---------------------------------------------------------------------------

local MONTH_NAMES = {
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"
}

local function format_datetime(dt_str)
  local year, month, day = dt_str:match("(%d+):(%d+):(%d+)")
  if not year then
    return nil
  end
  month = tonumber(month)
  if month < 1 or month > 12 then
    return nil
  end
  return string.format("%s %s, %s", MONTH_NAMES[month], day, year)
end

-- ---------------------------------------------------------------------------
-- Geolocation reverse lookup via OSM Nominatim
-- ---------------------------------------------------------------------------

local function lookup_place_name(latitude, longitude)
  dt.print_log("Nominatim lookup: lat=" .. tostring(latitude) .. " lon=" .. tostring(longitude))
  local url = ("https://nominatim.openstreetmap.org/reverse?format=json&lat=%s&lon=%s&zoom=10&addressdetails=1"):format(
    tostring(latitude), tostring(longitude)
  )

  local resp_tmpfile = os.tmpname()
  local err_tmpfile = os.tmpname()

  local curl_cmd = string.format(
    'curl -s --max-time 15 -H "User-Agent: ai_caption" "%s" > %s 2> %s',
    url,
    resp_tmpfile,
    err_tmpfile
  )

  local ret = os.execute(curl_cmd)

  local response = ""
  local resp_f = io.open(resp_tmpfile, "r")
  if resp_f then
    response = resp_f:read("*a")
    resp_f:close()
  end
  os.remove(resp_tmpfile)
  os.remove(err_tmpfile)

  if not response or #response == 0 then
    dt.print_log("Nominatim lookup: empty response")
    return nil
  end

  dt.print_log("Nominatim response: " .. response:sub(1, 300))

  local data = json_parse(response)
  if not data or not data.address then
    dt.print_log("Nominatim lookup: no address in response")
    return nil
  end

  local addr = data.address
  local country = addr.country or nil

  local place_parts = {}

  if addr.town or addr.city or addr.village or addr.municipality then
    table.insert(place_parts, addr.town or addr.city or addr.village or addr.municipality)
  end

  if addr.county then
    table.insert(place_parts, addr.county)
  end

  if addr.state then
    table.insert(place_parts, addr.state)
  end

  if country then
    table.insert(place_parts, country)
  end

  if #place_parts > 0 then
    local place = table.concat(place_parts, ", ")
    dt.print_log("Nominatim place: " .. place)
    return place
  end

  if data.display_name then
    local parts = {}
    for part in data.display_name:gmatch("[^,]+") do
      local trimmed = part:match("^%s*(.-)%s*$")
      if #trimmed > 0 and #trimmed < 60 then
        parts[#parts + 1] = trimmed
      end
      if #parts >= 3 then
        break
      end
    end
    if #parts > 0 then
      local place = table.concat(parts, ", ")
      dt.print_log("Nominatim place: " .. place .. " (display_name)")
      return place
    end
  end

  dt.print_log("Nominatim lookup: no place found")
  return nil
end

-- ---------------------------------------------------------------------------
-- VLM request building and sending
-- ---------------------------------------------------------------------------

local function build_vlm_request(image_path, options)
  options = options or {}

  local endpoint = options.endpoint or "http://localhost:8080/v1/chat/completions"
  local model = options.model or ""
  local max_tokens = options.max_tokens or 4096
  local temperature = options.temperature or 0.3
  local place_name = nil
  local capture_date = nil
  local filmroll_context = nil
  local photo_credit = nil
  if options.image_obj then
    if options.image_obj.latitude and options.image_obj.longitude then
      place_name = lookup_place_name(options.image_obj.latitude, options.image_obj.longitude)
    end
    local dt_str = options.image_obj.exif_datetime_taken
    if dt_str and dt_str ~= "" then
      capture_date = format_datetime(dt_str)
    end
    local path_parts = {}
    for part in (options.image_obj.path .. "/"):gmatch("([^/]+)/") do
      path_parts[#path_parts + 1] = part
    end
    if #path_parts >= 2 then
      local filmroll = path_parts[#path_parts]
      filmroll_context = extract_filmroll_context(filmroll)
    end
    local publisher = options.image_obj.publisher
    local creator = options.image_obj.creator
    if publisher and publisher ~= "" and creator and creator ~= "" then
      photo_credit = publisher .. "/" .. creator
    elseif publisher and publisher ~= "" then
      photo_credit = publisher
    elseif creator and creator ~= "" then
      photo_credit = creator
    end
  end

  local prompt = options.prompt or ("Analyze this image and provide a concise title and description in JSON format.\n"
    .. "Rules:\n"
    .. "- Title: A short, descriptive title (max 80 characters)\n"
    .. "- Description: Follow AP Photo editorial caption style:\n"
    .. "  Sentence 1 (present tense): Who and what, where and when.\n"
    .. "  Sentence 2 (past tense): Why or how the event occurred (context).\n"
    .. "- End the description with a photo credit in parentheses: (Publisher/Photographer)\n"
    .. "- Include location details (city, province/state, country) and date if available.\n"
    .. "- If the image is aerial, satellite, or taken from a specific vantage point, mention it.\n"
    .. "- Return ONLY valid JSON with keys \"title\" and \"description\"\n"
    .. "- Do not include any markdown formatting, backticks, or explanation text")

  if filmroll_context then
    prompt = prompt .. ("\n\nContext: This image relates to %s. "
      .. "Incorporate this context into the description.")
      :format(filmroll_context)
  end

  if capture_date then
    prompt = prompt .. ("\n\nDate: This photo was taken on %s. "
      .. "Incorporate this date into the description to provide temporal context (e.g., season, time of day).")
      :format(capture_date)
  end

  if place_name then
    prompt = prompt .. ("\n\nLocation: This photo was taken near \"%s\". "
      .. "Incorporate this location into the description to provide geographic context.")
      :format(place_name)
  end

  if options.additional_context and options.additional_context ~= "" then
    prompt = prompt .. ("\n\nUser Context: %s. "
      .. "Please incorporate this additional context into the title and description.")
      :format(options.additional_context)
  end

  if photo_credit then
    prompt = prompt .. ("\n\nPhoto credit: Use \"%s\" for the photo credit at the end of the description.")
      :format(photo_credit)
  end

  if options.title and options.title ~= "" then
    prompt = prompt .. "\n\nCurrent title: " .. options.title
  end
  if options.description and options.description ~= "" then
    prompt = prompt .. "\nCurrent description: " .. options.description
  end

  local max_dim = options.max_dim or 1024
  local encoded, tmpfile = encode_image_resized(image_path, max_dim)
  if not encoded then
    return nil, tmpfile
  end

  local data_uri = "data:image/jpeg;base64," .. encoded

  local request_body = json.encode({
    model = model,
    messages = {
      {
        role = "user",
        content = {
          { type = "text", text = prompt },
          { type = "image_url", image_url = { url = data_uri } }
        }
      }
    },
    max_tokens = max_tokens,
    temperature = temperature,
  })

  return request_body, endpoint, tmpfile
end

local function call_vlm(image_path, options)
  options = options or {}

  local request_body, endpoint, tmpfile = build_vlm_request(image_path, options)
  if not request_body then
    return nil, endpoint
  end

  local req_tmpfile = os.tmpname()
  local req_f = io.open(req_tmpfile, "w")
  if not req_f then
    os.remove(tmpfile)
    return nil, "Cannot create temp file for request"
  end
  req_f:write(request_body)
  req_f:close()

  dt.print_log("request body size: " .. #request_body .. " bytes")
  dt.print_log("request body preview: " .. request_body:sub(1, 200))

  local resp_tmpfile = os.tmpname()
  local err_tmpfile = os.tmpname()

  local curl_cmd = string.format(
    'curl -s --max-time 120 -X POST -H "Content-Type: application/json" -d @%s "%s" > %s 2> %s',
    req_tmpfile,
    endpoint,
    resp_tmpfile,
    err_tmpfile
  )

  dt.print_log("curl command: " .. curl_cmd)

  local ret = os.execute(curl_cmd)
  os.remove(req_tmpfile)

  local response = ""
  local resp_f = io.open(resp_tmpfile, "r")
  if resp_f then
    response = resp_f:read("*a")
    resp_f:close()
  end
  os.remove(resp_tmpfile)

  local err_output = ""
  local err_f = io.open(err_tmpfile, "r")
  if err_f then
    err_output = err_f:read("*a")
    err_f:close()
  end
  os.remove(err_tmpfile)

  dt.print_log("curl exit code: " .. tostring(ret))
  dt.print_log("curl stderr: " .. err_output)
  dt.print_log("curl output: " .. response)

  if err_output and #err_output > 0 then
    os.remove(tmpfile)
    return nil, "VLM API call failed: " .. err_output
  end

  os.remove(tmpfile)

  return parse_vlm_response(response), nil
end

-- ---------------------------------------------------------------------------
-- Grouped image path resolution
-- ---------------------------------------------------------------------------

local function resolve_image_path(image_path, image_obj)
  if not image_obj or #image_obj:get_group_members() <= 1 then
    return image_path
  end

  local members = image_obj:get_group_members()
  local jpeg_path = nil

  for _, member in ipairs(members) do
    if not member.is_raw then
      jpeg_path = member.path .. "/" .. member.filename
      break
    end
  end

  if jpeg_path then
    return jpeg_path
  end

  return image_path
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local ai_vlm = {
  json_parse = json_parse,
  encode_base64 = encode_base64,
  encode_image = encode_image,
  resize_image = resize_image,
  encode_image_resized = encode_image_resized,
  escape_json_string = escape_json_string,
  extract_json = extract_json,
  parse_vlm_response = parse_vlm_response,
  build_vlm_request = build_vlm_request,
  call_vlm = call_vlm,
  resolve_image_path = resolve_image_path,
  lookup_place_name = lookup_place_name,
  format_datetime = format_datetime,
  extract_filmroll_context = extract_filmroll_context,
}

return ai_vlm
