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
    ai_caption
    Uses a local AI VLM via OpenAI-compatible endpoint to suggest title
    and description metadata for a single selected photo in darktable.

    It adds additioanl context from geolocation, capture date, notes,
    creator and publisher metadata to suggest an AP Photo style caption.

    USAGE
    * require this file from your main lua config file (luarc):
        require "ai_caption"
    * A new panel "AI Caption" will appear in lighttable
    * Select an image and click "Suggest" to get AI-generated title/description
    * Edit the suggestions, then click "Apply" to store in metadata
    * Click "Clear" to clear the dialog fields
    * Use the "Additional context" field to provide extra information
      (e.g., event name, people, mood) for richer captions
]]

local dt = require "darktable"
local du = require "lib/dtutils"
local av = require "ai_caption/lua/lib/ai_vlm"

du.check_min_api_version("7.0.0", "ai_caption")

local gettext = dt.gettext.gettext

local function _(msgid)
  return gettext(msgid)
end

-- ---------------------------------------------------------------------------
-- Configuration / Preferences
-- ---------------------------------------------------------------------------

dt.preferences.register(
  "ai_caption",
  "vlm_endpoint",
  "string",
  _("VLM API Endpoint URL"),
  _("Full URL of the OpenAI-compatible VLM endpoint (e.g. http://localhost:8000/v1/chat/completions)"),
  "http://localhost:8000/v1/chat/completions"
)

dt.preferences.register(
  "ai_caption",
  "vlm_model",
  "string",
  _("VLM Model Name"),
  _("Name of the model to use for suggestions"),
  ""
)

dt.preferences.register(
  "ai_caption",
  "vlm_max_tokens",
  "integer",
  _("VLM Max Tokens"),
  _("Maximum number of tokens in the VLM response"),
  4096,
  50,
  8192
)

dt.preferences.register(
  "ai_caption",
  "vlm_temperature",
  "float",
  _("VLM Temperature"),
  _("Creativity level for VLM generation (0.0 - 1.0)"),
  0.6,
  0.0,
  1.0,
  0.1
)

dt.preferences.register(
  "ai_caption",
  "vlm_max_dim",
  "integer",
  _("VLM Max Image Dimension"),
  _("Maximum dimension (longest side) for image resize before sending to VLM (pixels)"),
  1024,
  256,
  4096
)

dt.preferences.register(
  "ai_caption",
  "panel_position",
  "enum",
  _("AI Caption Panel Position"),
  _("Panel location in the lighttable view"),
  "DT_UI_CONTAINER_PANEL_RIGHT_CENTER",
  "DT_UI_CONTAINER_PANEL_RIGHT_CENTER",
  "DT_UI_CONTAINER_PANEL_RIGHT_BOTTOM",
  "DT_UI_CONTAINER_PANEL_LEFT_CENTER",
  "DT_UI_CONTAINER_PANEL_LEFT_BOTTOM"
)

-- ---------------------------------------------------------------------------
-- VLM API call
-- ---------------------------------------------------------------------------

local function call_vlm(image_path, title, description, additional_context, notes, image_obj)
  local endpoint = dt.preferences.read("ai_caption", "vlm_endpoint", "string")
  local model = dt.preferences.read("ai_caption", "vlm_model", "string")
  local max_tokens = dt.preferences.read("ai_caption", "vlm_max_tokens", "integer")
  local temperature = dt.preferences.read("ai_caption", "vlm_temperature", "float")
  local max_dim = dt.preferences.read("ai_caption", "vlm_max_dim", "integer")

  local combined_context = additional_context
  if notes and notes ~= "" then
    if combined_context and combined_context ~= "" then
      combined_context = combined_context .. "\n\nPhoto notes: " .. notes
    else
      combined_context = "Photo notes: " .. notes
    end
  end

  local result, err = av.call_vlm(image_path, {
    endpoint = endpoint,
    model = model,
    max_tokens = max_tokens,
    temperature = temperature,
    max_dim = max_dim,
    title = title,
    description = description,
    additional_context = combined_context,
    image_obj = image_obj,
  })

  if err then
    dt.print_error(err)
  end

  return result
end

-- ---------------------------------------------------------------------------
-- Save metadata from fields to image
-- ---------------------------------------------------------------------------

local function save_to_group(img, title, description)
  if #img:get_group_members() > 1 then
    for _, member in ipairs(img:get_group_members()) do
      member.title = title
      member.description = description
    end
    dt.print_log(_("Saved to group: ") .. img.filename)
  else
    img.title = title
    img.description = description
    dt.print_log(_("Saved title and description to: ") .. img.filename)
  end
end

-- ---------------------------------------------------------------------------
-- Panel state
-- ---------------------------------------------------------------------------

local module_installed = false
local _module_lib = nil
local _title_entry_ref = nil
local _desc_text_ref = nil
local _additional_text_ref = nil

local function get_panel_fields()
  local title = ""
  local description = ""
  local additional = ""
  if _title_entry_ref then
    title = _title_entry_ref.text or ""
  end
  if _desc_text_ref then
    description = _desc_text_ref.text or ""
  end
  if _additional_text_ref then
    additional = _additional_text_ref.text or ""
  end
  return title, description, additional
end

local function populate_panel_fields(title, description, additional)
  if not _title_entry_ref and not _desc_text_ref and not _additional_text_ref then
    dt.print_log("populate_panel_fields: panel not installed yet, skipping")
    return
  end
  if _title_entry_ref then
    _title_entry_ref.text = title or ""
  end
  if _desc_text_ref then
    _desc_text_ref.text = description or ""
  end
  if _additional_text_ref then
    _additional_text_ref.text = additional or ""
  end
end

-- ---------------------------------------------------------------------------
-- Main action: Suggest
-- ---------------------------------------------------------------------------

local function action_suggest()
  if not dt.gui.action_images or #dt.gui.action_images == 0 then
    dt.print_error(_("No image selected"))
    return
  end

  local image = dt.gui.action_images[1]
  local image_path = image.path .. "/" .. image.filename
  image_path = av.resolve_image_path(image_path, image)

  local current_title = image.title or ""
  local current_desc = image.description or ""
  local current_additional = ""
  local current_notes = image.notes or ""

  if _additional_text_ref then
    current_additional = _additional_text_ref.text or ""
  end

  dt.print_log(_("Suggesting caption for: ") .. image.filename)
  dt.print(_("Analyzing image with AI..."))

  local result = call_vlm(image_path, current_title, current_desc, current_additional, current_notes, image)

  if result then
    dt.print_log(_("AI suggestion received"))
    dt.print_log(_("Title: ") .. result.title)
    dt.print_log(_("Description: ") .. result.description)
    dt.print(_("AI suggestion received. Edit and apply."))
    populate_panel_fields(result.title, result.description, current_additional)
  else
    dt.print_error(_("AI suggestion failed. Check endpoint and model settings."))
  end
end

-- ---------------------------------------------------------------------------
-- Main action: Apply
-- ---------------------------------------------------------------------------

local function action_apply()
  local title, description = get_panel_fields()

  if not title and not description then
    dt.print_error(_("No title or description set. Use Suggest first."))
    return
  end

  local img = dt.gui.action_images and dt.gui.action_images[1]
  if img then
    save_to_group(img, title, description)
  end

  dt.print(_("Title and description saved"))
end

-- ---------------------------------------------------------------------------
-- Main action: Clear
-- ---------------------------------------------------------------------------

local function action_clear()
  if _title_entry_ref then
    _title_entry_ref.text = ""
  end
  if _desc_text_ref then
    _desc_text_ref.text = ""
  end
  if _additional_text_ref then
    _additional_text_ref.text = ""
  end
  dt.print(_("Fields cleared"))
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------

local function install_module()
  if module_installed then return end

  local suggest_button = dt.new_widget("button") {
    label = _("Suggest"),
    tooltip = _("Use AI to suggest title and description for selected image"),
    clicked_callback = function()
      action_suggest()
    end,
  }

  local apply_button = dt.new_widget("button") {
    label = _("Apply"),
    tooltip = _("Save title and description to image metadata"),
    clicked_callback = function()
      action_apply()
    end,
  }

  local clear_button = dt.new_widget("button") {
    label = _("Clear"),
    tooltip = _("Clear title, description, and additional context fields"),
    clicked_callback = function()
      action_clear()
    end,
  }

  local title_entry = dt.new_widget("entry") {
    tooltip = _("Title for the image"),
  }

  local title_field = dt.new_widget("box") {
    orientation = "vertical",
    dt.new_widget("label") { label = _("Title:"), halign = "start" },
    title_entry,
  }

  local desc_text = dt.new_widget("text_view") {
    tooltip = _("Description for the image"),
    editable = true,
  }
  desc_text.text = ""

  local desc_field = dt.new_widget("box") {
    orientation = "vertical",
    expand = true,
    dt.new_widget("label") { label = _("Description:"), halign = "start" },
    desc_text,
  }

  local additional_text = dt.new_widget("text_view") {
    tooltip = _("Additional context to help generate better captions (e.g., event name, people, mood)"),
    editable = true,
  }
  additional_text.text = ""

  local additional_field = dt.new_widget("box") {
    orientation = "vertical",
    expand = true,
    dt.new_widget("label") { label = _("Additional context:"), halign = "start" },
    additional_text,
  }

  local info_label = dt.new_widget("label") {
    label = _("AI Caption"),
  }

  local button_box = dt.new_widget("box") {
    orientation = "horizontal",
    suggest_button,
    apply_button,
    clear_button,
  }

  local module_box = dt.new_widget("box") {
    orientation = "vertical",
    info_label,
    dt.new_widget("separator") {},
    title_field,
    desc_field,
    additional_field,
    dt.new_widget("separator") {},
    button_box,
  }

  local panel_pos = dt.preferences.read("ai_caption", "panel_position", "enum")

  _module_lib = dt.register_lib(
    "ai_caption",
    _("AI Caption"),
    true,
    false,
    {[dt.gui.views.lighttable] = {panel_pos, 0}},
    module_box
  )

  _title_entry_ref = title_entry
  _desc_text_ref = desc_text
  _additional_text_ref = additional_text

  module_installed = true
end

-- ---------------------------------------------------------------------------
-- Destroy / Cleanup
-- ---------------------------------------------------------------------------

local function destroy()
  if _module_lib then
    _module_lib.visible = false
  end
end

-- ---------------------------------------------------------------------------
-- Entry Point
-- ---------------------------------------------------------------------------

local script_data = {}

script_data.metadata = {
  name = _("AI Caption"),
  purpose = _("Uses local AI VLM to suggest Title/Description metadata with additional context for photos"),
  author = "<your-name>",
  help = ""
}

script_data.destroy = destroy
script_data.destroy_method = "hide"

if dt.gui.current_view().id == "lighttable" then
  install_module()
else
  dt.register_event(
    "ai_caption_view",
    "view-changed",
    function(event, old_view, new_view)
      if new_view.name == "lighttable" then
        install_module()
      end
    end
  )
end

return script_data

-- vim: shiftwidth=2 expandtab tabstop=2 cindent syntax=lua
