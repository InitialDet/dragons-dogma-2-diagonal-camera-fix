-- Dragon's Dogma 2 Controller Diagonal Camera Fix
--
-- How it works:
--   The game calls getInputRotationSpeedRate once per axis (X, then Y). Each call
--   only sees its own axis, so on its own it can't know the stick's true
--   magnitude. Instead of guessing, we read the real right-stick vector (x, y)
--   from the gamepad, compute ONE magnitude from it, and scale whichever axis
--   value the hook is currently handling by the same factor. Both axes always
--   get the same factor, so the direction of the stick is preserved exactly.
--
-- If the gamepad can't be read (or the mouse is being used), the game's own
-- value is passed through untouched.
------------------------------------------------------------------------------
-- Settings (saved to ControllerDiagonalFix.json)
------------------------------------------------------------------------------
local config = json.load_file("ControllerDiagonalFix.json") or {}
if config.mode == nil then
    config.mode = 0 -- 0 = Linear, 1 = Power Curve
end
if config.dead_zone == nil then
    config.dead_zone = 0.15
end
if config.curve_power == nil then
    config.curve_power = 1.5
end
if config.show_debug == nil then
    config.show_debug = false
end
if config.enabled == nil then
    config.enabled = true
end

local MODE_LINEAR = 0
local MODE_POWER_CURVE = 1

local function save_settings()
    json.dump_file("ControllerDiagonalFix.json", config)
end

------------------------------------------------------------------------------
-- State
------------------------------------------------------------------------------

-- Values shown by the debug panel and overlay
local debug_raw_x, debug_raw_y = 0, 0 -- axis values the game passed to the hook
local debug_out_x, debug_out_y = 0, 0 -- axis values we returned
local pad_stick_x, pad_stick_y = 0, 0 -- right stick as read from the gamepad
local pad_read_ok = false
local debug_game_rate = 0
local display_width, display_height = 1920, 1080

local DEAD_ZONE_MAX = 0.40

-- Auto detection: lowest stick magnitude at which the game registers movement
local auto_detect_dead_zone = true
local detected_dead_zone = DEAD_ZONE_MAX

-- State of the hook call currently in flight (shared by pre- and post-hook)
local AXIS_X = 1 -- first call of a frame
local AXIS_Y = 2 -- second call of a frame
local hook_passthrough = true
local current_axis_value = 0
local current_stick_magnitude = 0
local current_axis = nil -- AXIS_X, AXIS_Y, or nil if this is not the main camera

-- Debug-only bookkeeping: how many hook calls each camera made this frame
local calls_per_camera = {}
local main_camera_address = nil

------------------------------------------------------------------------------
-- Gamepad access
------------------------------------------------------------------------------

-- Resolved lazily: the singleton may not exist yet when this script loads.
local gamepad_type = nil
local gamepad_singleton = nil
local pad_last_fail_reason = "not read yet"
local pad_fail_count = 0

-- After this many consecutive failed reads the cached handles are dropped and
-- looked up again. Native singletons can be torn down and recreated (input
-- device changes, game re-init), which would otherwise leave a stale pointer
-- cached for the rest of the session.
local PAD_RECACHE_AFTER = 30
local pad_consecutive_fails = 0

-- Records a failed read and returns nil, so callers can `return pad_failed(...)`.
local function pad_failed(reason)
    pad_last_fail_reason = reason
    pad_fail_count = pad_fail_count + 1
    pad_consecutive_fails = pad_consecutive_fails + 1
    if pad_consecutive_fails >= PAD_RECACHE_AFTER then
        gamepad_type = nil
        gamepad_singleton = nil
        pad_consecutive_fails = 0
    end
    return nil
end

local function resolve_gamepad()
    if not gamepad_type then
        gamepad_type = sdk.find_type_definition("via.hid.GamePad")
    end
    if not gamepad_singleton then
        gamepad_singleton = sdk.get_native_singleton("via.hid.GamePad")
    end
    return gamepad_type ~= nil and gamepad_singleton ~= nil
end

-- Current right-stick vector, or nil if unavailable (reason stored for the debug panel).
local function read_right_stick()
    if not resolve_gamepad() then
        return pad_failed("GamePad type/singleton not found")
    end

    local read_ok, stick_x, stick_y = pcall(function()
        local input_device = sdk.call_native_func(gamepad_singleton, gamepad_type, "get_LastInputDevice")
        if not input_device then
            return "no_device"
        end
        local stick_axis = input_device:get_AxisR()
        return stick_axis.x, stick_axis.y
    end)

    if read_ok and type(stick_x) == "number" and type(stick_y) == "number" then
        pad_consecutive_fails = 0
        return stick_x, stick_y
    end

    if read_ok and stick_x == "no_device" then
        return pad_failed("no last input device")
    elseif read_ok then
        return pad_failed("last input device has no usable AxisR")
    end
    return pad_failed("read error (device may not be a pad)")
end

------------------------------------------------------------------------------
-- Dead zone and curve math
------------------------------------------------------------------------------

local function effective_dead_zone()
    local dead_zone = auto_detect_dead_zone and detected_dead_zone or config.dead_zone
    return math.min(dead_zone, DEAD_ZONE_MAX)
end

-- Factor that turns an axis value into its output value, given the stick's
-- magnitude. Magnitude is clamped to 1.0 for the remap (so square-gate corners
-- aren't faster than straight pushes) but the final division uses the real
-- magnitude so the direction is untouched.
local function scale_for_magnitude(magnitude, dead_zone)
    if magnitude <= dead_zone then
        return 0
    end
    local clamped_magnitude = math.min(magnitude, 1.0)
    local remapped = (clamped_magnitude - dead_zone) / (1.0 - dead_zone)
    if config.mode == MODE_POWER_CURVE then
        remapped = remapped ^ config.curve_power
    end
    return remapped / magnitude
end

------------------------------------------------------------------------------
-- Hook
------------------------------------------------------------------------------

local camera_type = sdk.find_type_definition("app.RotateCameraControllerBase")
local rotation_speed_method = camera_type and camera_type:get_method("getInputRotationSpeedRate")
if not rotation_speed_method then
    log.error("[DiagFix] Failed to find getInputRotationSpeedRate - script will not work")
end

sdk.hook(rotation_speed_method, function(args)
    hook_passthrough = true
    current_axis = nil
    local axis_value = sdk.to_float(args[3]) or 0

    local camera = sdk.to_managed_object(args[2])
    if not camera then
        return sdk.PreHookResult.CALL_ORIGINAL
    end

    -- Mouse aiming never goes through the stick curve
    local mouse_moved = false
    local call_ok, call_result = pcall(function()
        return camera:get_IsMouseMovedInFrame()
    end)
    if call_ok then
        mouse_moved = call_result
    end
    if mouse_moved then
        return sdk.PreHookResult.CALL_ORIGINAL
    end

    -- Real stick vector for this frame
    local stick_x, stick_y = read_right_stick()
    pad_read_ok = (stick_x ~= nil)
    if not pad_read_ok then
        return sdk.PreHookResult.CALL_ORIGINAL
    end
    pad_stick_x, pad_stick_y = stick_x, stick_y

    local stick_magnitude = math.sqrt(stick_x * stick_x + stick_y * stick_y)
    if stick_magnitude < 1e-6 and axis_value ~= 0 then
        -- Pad says "centered" but the game has input: don't trust the pad here
        return sdk.PreHookResult.CALL_ORIGINAL
    end

    hook_passthrough = false
    current_axis_value = axis_value
    current_stick_magnitude = stick_magnitude

    -- Debug bookkeeping (main camera only)
    local camera_address = camera:get_address()
    calls_per_camera[camera_address] = (calls_per_camera[camera_address] or 0) + 1
    if not main_camera_address then
        main_camera_address = camera_address
    end
    if camera_address == main_camera_address then
        local call_index = calls_per_camera[camera_address]
        if call_index == 1 then
            current_axis = AXIS_X
            debug_raw_x = axis_value
        elseif call_index == 2 then
            current_axis = AXIS_Y
            debug_raw_y = axis_value
        end
    end

    return sdk.PreHookResult.CALL_ORIGINAL
end, function(return_value)
    if hook_passthrough then
        return return_value
    end

    local game_rate = sdk.to_float(return_value) or 0
    debug_game_rate = game_rate

    -- Detect the dead zone from the game's own idea of "moving". Whenever this
    -- lowers the threshold, current_stick_magnitude == detected_dead_zone on this
    -- frame, so the output below is 0 (the dead zone edge maps to 0). That is the
    -- same as any other frame sitting exactly on the edge, and the next frame
    -- already uses the new threshold.
    if auto_detect_dead_zone and math.abs(game_rate) > 0.001 and current_stick_magnitude > 0 and current_stick_magnitude <
        detected_dead_zone then
        detected_dead_zone = current_stick_magnitude
    end

    local output_value
    if config.enabled then
        output_value = current_axis_value * scale_for_magnitude(current_stick_magnitude, effective_dead_zone())
    else
        output_value = current_axis_value
    end

    if current_axis == AXIS_X then
        debug_out_x = output_value
    elseif current_axis == AXIS_Y then
        debug_out_y = output_value
    end

    if config.enabled then
        return sdk.float_to_ptr(output_value)
    end
    return return_value
end)

re.on_frame(function()
    calls_per_camera = {}
    main_camera_address = nil
end)

------------------------------------------------------------------------------
-- Menu
------------------------------------------------------------------------------

local function info_icon(tooltip_text)
    imgui.same_line()
    imgui.text_colored("(?)", 0xFF8888FF)
    if imgui.is_item_hovered() then
        imgui.set_tooltip(tooltip_text)
    end
end

re.on_draw_ui(function()
    local display_size = imgui.get_display_size()
    if display_size then
        display_width, display_height = display_size.x, display_size.y
    end
    if not imgui.tree_node("Controller Diagonal Fix") then
        return
    end

    local enabled_changed, enabled_value = imgui.checkbox("Enabled", config.enabled)
    if enabled_changed then
        config.enabled = enabled_value
        save_settings()
    end

    imgui.set_next_item_width(imgui.calc_text_size("Power Curve").x + 36)
    local mode_changed, new_mode_index = imgui.combo("Mode", config.mode + 1, {"Linear", "Power Curve"})
    if mode_changed then
        config.mode = new_mode_index - 1
        save_settings()
    end
    info_icon(
        "Linear: scales stick input linearly from dead zone to 1.0.\nPower Curve: applies an exponential curve for finer low-speed control.")

    if config.mode == MODE_POWER_CURVE then
        local power_changed, new_curve_power = imgui.slider_float("Curve power", config.curve_power, 1.0, 3.0, "%.2f")
        if power_changed then
            config.curve_power = new_curve_power
            save_settings()
        end
        info_icon(
            "Higher values = more stick output at high tilt, less at low tilt.\n1.0 = linear, 2.0 = quadratic, 3.0 = cubic.")
    end

    local auto_detect_changed, auto_detect_value = imgui.checkbox("Detect Dead Zone Automatically",
        auto_detect_dead_zone)
    if auto_detect_changed then
        auto_detect_dead_zone = auto_detect_value
    end
    info_icon(
        "Tracks the minimum stick movement the game registers and uses it as the dead zone.\nThreshold shows the current detected minimum.")
    imgui.same_line()
    imgui.text(string.format("Threshold: %.3f", detected_dead_zone))
    if not auto_detect_dead_zone then
        local dead_zone_changed, new_dead_zone = imgui.slider_float("Dead zone", config.dead_zone, 0.0, DEAD_ZONE_MAX,
            "%.3f")
        if dead_zone_changed then
            config.dead_zone = new_dead_zone
            save_settings()
        end
        info_icon("Manual dead zone. Stick input below this value is ignored.\nOnly used when Detect Dead Zone is off.")
    end

    local debug_changed, debug_value = imgui.checkbox("Show Debug", config.show_debug)
    if debug_changed then
        config.show_debug = debug_value
        save_settings()
    end
    info_icon(
        "Shows a 2D stick overlay (centered) and a curve graph (bottom-right)\nwith raw input, output, dead zone, and speed readouts.")

    if config.show_debug then
        local dead_zone = effective_dead_zone()
        local power_suffix = config.mode == MODE_POWER_CURVE and string.format(" | Pow: %.2f", config.curve_power) or ""
        imgui.text(string.format("Raw: %.3f, %.3f | Out: %.3f, %.3f | DZ: %.3f%s", debug_raw_x, debug_raw_y,
            debug_out_x, debug_out_y, dead_zone, power_suffix))
        imgui.text(string.format("Game rate: %.4f", debug_game_rate))
        imgui.text(string.format("Pad: %s | Stick: %.3f, %.3f", pad_read_ok and "OK" or "UNAVAILABLE (passthrough)",
            pad_stick_x, pad_stick_y))
        imgui.text(string.format("Pad failures: %d | Last reason: %s", pad_fail_count, pad_last_fail_reason))
        if imgui.button("Reset failure count") then
            pad_fail_count = 0
        end
        imgui.text(string.format("Raw mag: %.3f | Stick mag: %.3f",
            math.sqrt(debug_raw_x * debug_raw_x + debug_raw_y * debug_raw_y),
            math.sqrt(pad_stick_x * pad_stick_x + pad_stick_y * pad_stick_y)))
    end

    imgui.tree_pop()
end)

------------------------------------------------------------------------------
-- Debug overlay
------------------------------------------------------------------------------

re.on_frame(function()
    if not config.show_debug then
        return
    end

    -- Stick plot (centered on screen)
    local plot_size = 160
    local plot_left = (display_width - plot_size) / 2
    local plot_top = (display_height - plot_size) / 2
    local plot_center_x = plot_left + plot_size / 2
    local plot_center_y = plot_top + plot_size / 2
    local stick_radius = plot_size / 2 * 0.85 -- on-screen pixels for a stick value of 1.0

    draw.filled_rect(plot_left, plot_top, plot_size, plot_size, 0xCC000000)
    draw.outline_rect(plot_left, plot_top, plot_size, plot_size, 0xFF888888)
    draw.line(plot_left, plot_center_y, plot_left + plot_size, plot_center_y, 0x44FFFFFF)
    draw.line(plot_center_x, plot_top, plot_center_x, plot_top + plot_size, 0x44FFFFFF)
    draw.outline_circle(plot_center_x, plot_center_y, stick_radius, 0x44FFFFFF, 32)

    if debug_raw_x ~= 0 or debug_raw_y ~= 0 then
        local raw_dot_x = plot_center_x - debug_raw_x * stick_radius
        local raw_dot_y = plot_center_y - debug_raw_y * stick_radius
        draw.filled_circle(raw_dot_x, raw_dot_y, 5, 0xFFFFFF44, 16)
        draw.text(string.format("Raw(%.2f)", math.sqrt(debug_raw_x * debug_raw_x + debug_raw_y * debug_raw_y)),
            raw_dot_x - 16, raw_dot_y + 6, 0xFFFFFF44)

        if config.enabled then
            local out_dot_x = plot_center_x - debug_out_x * stick_radius
            local out_dot_y = plot_center_y - debug_out_y * stick_radius
            draw.line(raw_dot_x, raw_dot_y, out_dot_x, out_dot_y, 0xAAFFFFFF)
            draw.filled_circle(out_dot_x, out_dot_y, 5, 0xFF44FF44, 16)
            draw.text(string.format("Out(%.2f)", math.sqrt(debug_out_x * debug_out_x + debug_out_y * debug_out_y)),
                out_dot_x - 16, out_dot_y + 6, 0xFF44FF44)
        end
    end

    local dead_zone = effective_dead_zone()
    local dead_zone_label = config.mode == MODE_POWER_CURVE and
                                string.format("DZ: %.3f | Pow: %.2f", dead_zone, config.curve_power) or
                                string.format("DZ: %.3f", dead_zone)
    local speed_label = string.format("Speed: %.3f, %.3f", debug_out_x, debug_out_y)
    draw.text(dead_zone_label, plot_center_x - imgui.calc_text_size(dead_zone_label).x / 2, plot_top + plot_size + 4,
        0xFF00FF00)
    draw.text(speed_label, plot_center_x - imgui.calc_text_size(speed_label).x / 2, plot_top + plot_size + 18,
        0xFF88FF88)

    -- Curve graph (bottom-right corner of the stick plot)
    local graph_left = plot_left + plot_size - 64
    local graph_top = plot_top + plot_size - 64
    local graph_size = 60
    draw.outline_rect(graph_left - 2, graph_top - 2, graph_size + 4, graph_size + 4, 0x88FFFFFF)
    draw.filled_rect(graph_left, graph_top, graph_size, graph_size, 0x66000000)
    draw.line(graph_left, graph_top + graph_size, graph_left + graph_size, graph_top + graph_size, 0x44FFFFFF)
    draw.line(graph_left, graph_top + graph_size, graph_left, graph_top, 0x44FFFFFF)

    -- Output magnitude for a given input magnitude (same curve as scale_for_magnitude)
    local function curve_output(input_magnitude, curve_dead_zone)
        if input_magnitude <= curve_dead_zone then
            return 0
        end
        local remapped = (input_magnitude - curve_dead_zone) / (1.0 - curve_dead_zone)
        if config.mode == MODE_POWER_CURVE then
            return remapped ^ config.curve_power
        end
        return remapped
    end

    local previous_point_x, previous_point_y
    for step = 0, graph_size do
        local input_magnitude = step / graph_size
        local output_magnitude = curve_output(input_magnitude, dead_zone)
        local point_x = graph_left + step
        local point_y = graph_top + graph_size - output_magnitude * graph_size
        if previous_point_x then
            draw.line(previous_point_x, previous_point_y, point_x, point_y, 0xFFFFFF88)
        end
        previous_point_x, previous_point_y = point_x, point_y
    end

    -- Mark the current stick magnitude on the curve
    local stick_magnitude = math.sqrt(pad_stick_x * pad_stick_x + pad_stick_y * pad_stick_y)
    if pad_read_ok and stick_magnitude > 0 then
        local clamped_magnitude = math.min(stick_magnitude, 1.0)
        local marker_x = graph_left + clamped_magnitude * graph_size
        local marker_y = graph_top + graph_size - curve_output(clamped_magnitude, dead_zone) * graph_size
        draw.filled_circle(marker_x, marker_y, 3, 0xFF44FF44, 8)
    end
end)
