-- Dragon's Dogma 2 Controller Diagonal Camera Fix
-- Two modes: Linear or Power Curve (magnitude-based, angle-preserving).
local config = json.load_file("ControllerDiagonalFix.json") or {}
if config.mode == nil then
    config.mode = 0
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

local function save_settings()
    json.dump_file("ControllerDiagonalFix.json", config)
end

local raw_x, raw_y = 0, 0
local out_x, out_y = 0, 0
local linear_out = 0

local dbg_output_rate = 0

local display_w, display_h = 1920, 1080

local recording = false
local recorded_data = {}
local rec_frame_id = 0
local rec_seq = 0

-- Auto calibration: tracks game_rate transitions to find dead zone
local auto_cal = true
local cal_detected = 1.0
local cal_frame_moving = false
local cal_frame_mag = 0

-- Per-camera state (for 2 cameras, each called twice per frame)
local cam_state = {}
local main_cam = nil

local function effective_dz()
    return auto_cal and cal_detected or config.dead_zone
end

local function info_icon(tip)
    imgui.same_line()
    imgui.text_colored("(?)", 0xFF8888FF)
    if imgui.is_item_hovered() then
        imgui.set_tooltip(tip)
    end
end

-- Linear with magnitude-based dead zone (angle-preserving)
local function apply_linear_dz(axis_val, mag, dz)
    if mag <= dz then
        return 0
    end
    local f = (mag - dz) / (1.0 - dz) / mag
    return axis_val * f
end

-- Power curve on magnitude (angle-preserving), with dead zone
local function apply_power_curve(axis_val, mag, dz)
    if mag <= dz then
        return 0
    end
    local remapped = (mag - dz) / (1.0 - dz)
    local cm = (remapped ^ config.curve_power) / mag
    return axis_val * cm
end

-- Raw value of the second axis (Y) from the previous frame. The hook is called
-- once per axis, so it needs this to build the magnitude of a frame.
local cam_prev_y = 0

-- Set by the pre-hook when a call cannot be remapped and must be left alone.
-- Without it the post-hook would answer such a call with whatever value the
-- previous call happened to leave behind.
local passthrough = false

local td = sdk.find_type_definition("app.RotateCameraControllerBase")
local method = td and td:get_method("getInputRotationSpeedRate")
if not method then
    log.error("[DiagFix] Failed to find method - script will not work")
end

sdk.hook(method, function(args)
    local raw = sdk.to_float(args[3]) or 0

    passthrough = false

    local cam = sdk.to_managed_object(args[2])
    if not cam then
        passthrough = true
        return sdk.PreHookResult.CALL_ORIGINAL
    end

    local is_mouse = false
    local ok, v = pcall(function()
        return cam:get_IsMouseMovedInFrame()
    end)
    if ok then
        is_mouse = v
    end

    if is_mouse then
        -- Mouse aiming never goes through the stick curve, so the game's own
        -- value is handed back untouched (linear_out only feeds the recording).
        linear_out = raw
        passthrough = true
        return sdk.PreHookResult.CALL_ORIGINAL
    end

    local ptr = cam:get_address()
    if not cam_state[ptr] then
        cam_state[ptr] = {
            call = 0,
            x = 0,
            y = 0
        }
        if not main_cam then
            main_cam = ptr
        end
    end
    local cs = cam_state[ptr]
    cs.call = cs.call + 1

    -- Only the second call of a frame sees both axis values, so the first call
    -- pairs its own value with the other axis of the previous frame. Both calls
    -- must then use that one magnitude: giving each axis a magnitude of its own
    -- scales the two axes differently and bends the direction of the movement.
    if cs.call == 1 then
        cs.x = raw
        cs.mag = math.sqrt(cs.x * cs.x + cam_prev_y * cam_prev_y)
    elseif cs.call == 2 then
        cs.y = raw
        if ptr == main_cam then
            cal_frame_mag = math.sqrt(cs.x * cs.x + cs.y * cs.y)
        end
    else
        cs.mag = math.sqrt(raw * raw + cs.x * cs.x)
    end

    if config.enabled then
        local dz = effective_dz()

        if config.mode == 0 then
            linear_out = apply_linear_dz(raw, cs.mag, dz)
        else
            linear_out = apply_power_curve(raw, cs.mag, dz)
        end

        if ptr == main_cam then
            if cs.call == 1 then
                out_x = linear_out
                raw_x = raw
            elseif cs.call == 2 then
                out_y = linear_out
                raw_y = raw
            end
        end

        args[3] = sdk.float_to_ptr(raw)
    else
        linear_out = raw
        if ptr == main_cam then
            if cs.call == 1 then
                out_x = raw
                raw_x = raw
            elseif cs.call == 2 then
                out_y = raw
                raw_y = raw
            end
        end
    end

    if recording then
        table.insert(recorded_data, string.format("%d,%.4f,%.4f,%.4f,%d,%d", cs.call, raw, linear_out, dbg_output_rate,
            rec_seq, rec_frame_id))
    end

    return sdk.PreHookResult.CALL_ORIGINAL
end, function(retval)
    local rate = sdk.to_float(retval) or 0
    dbg_output_rate = rate

    if math.abs(rate) > 0.001 then
        cal_frame_moving = true
    end

    if config.enabled and not passthrough then
        return sdk.float_to_ptr(linear_out)
    end
    return retval
end)

re.on_frame(function()
    if auto_cal and cal_frame_moving and cal_frame_mag > 0 then
        if cal_frame_mag < cal_detected then
            cal_detected = cal_frame_mag
        end
    end

    if main_cam and cam_state[main_cam] then
        cam_prev_y = cam_state[main_cam].y
    end

    rec_seq = rec_seq + 1
    cal_frame_moving = false
    cal_frame_mag = 0
    cam_state = {}
    main_cam = nil
end)

re.on_draw_ui(function()
    local ds = imgui.get_display_size()
    if ds then
        display_w, display_h = ds.x, ds.y
    end
    if not imgui.collapsing_header("Controller Diagonal Fix") then
        return
    end

    local c1, v1 = imgui.checkbox("Enabled", config.enabled)
    if c1 then
        config.enabled = v1;
        save_settings()
    end

    imgui.set_next_item_width(imgui.calc_text_size("Power Curve").x + 36)
    local cm, nm = imgui.combo("Mode", config.mode + 1, {"Linear", "Power Curve"})
    if cm then
        config.mode = nm - 1;
        save_settings()
    end
    info_icon(
        "Linear: scales stick input linearly from dead zone to 1.0.\nPower Curve: applies an exponential curve for finer low-speed control and sharper highs.")

    if config.mode == 1 then
        local c4, v4 = imgui.slider_float("Curve power", config.curve_power, 1.0, 3.0, "%.2f")
        if c4 then
            config.curve_power = v4;
            save_settings()
        end
        info_icon(
            "Higher values = more stick output at high tilt, less at low tilt.\n1.0 = linear, 2.0 = quadratic, 3.0 = cubic.")
    end

    local c2, v2 = imgui.checkbox("Detect Dead Zone Automatically", auto_cal)
    if c2 then
        auto_cal = v2
    end
    info_icon(
        "Tracks the minimum stick movement the game registers and uses it as the dead zone.\nThreshold shows the current detected minimum.")
    imgui.same_line()
    imgui.text(string.format("Threshold: %.3f", cal_detected))
    if not auto_cal then
        local c3, v3 = imgui.slider_float("Dead zone", config.dead_zone, 0.0, 0.40, "%.3f")
        if c3 then
            config.dead_zone = v3;
            save_settings()
        end
        info_icon("Manual dead zone. Stick input below this value is ignored.\nOnly used when Detect Dead Zone is off.")
    end

    local c3, v3 = imgui.checkbox("Show Debug", config.show_debug)
    if c3 then
        config.show_debug = v3;
        save_settings()
    end
    info_icon(
        "Shows a 2D stick overlay (centered) and a curve graph (bottom-right)\nwith raw input, output, dead zone, and speed readouts.")

    local rl = recording and "Stop" or "Record"
    local rc = nil
    local _ = nil

    if config.show_debug then
        local dz = effective_dz()
        local extra = config.mode == 1 and string.format(" | Pow: %.2f", config.curve_power) or ""
        imgui.text(
            string.format("Raw: %.3f, %.3f | Out: %.3f, %.3f | DZ: %.3f%s", raw_x, raw_y, out_x, out_y, dz, extra))
        imgui.text(string.format("Game rate: %.4f", dbg_output_rate))
        -- rc, _ = imgui.button(rl)
    end

    if rc then
        if recording then
            recording = false
            local header = "call,input,output,game_rate,seq,session"
            local csv = table.concat(recorded_data, "\n")
            sdk.copy_to_clipboard(header .. "\n" .. csv)
            log.info("[DiagFix] Recorded %d samples", #recorded_data)
            recorded_data = {}
        else
            recording = true
            recorded_data = {}
            rec_frame_id = rec_frame_id + 1
            log.info("[DiagFix] Recording started")
        end
    end
    if recording then
        imgui.same_line()
        imgui.text_colored(string.format("%d", #recorded_data), 0xFFFF0000)
    end
end)

re.on_frame(function()
    if not config.show_debug then
        return
    end

    local plot_size = 160
    local ox = (display_w - plot_size) / 2
    local oy = (display_h - plot_size) / 2
    local cx = ox + plot_size / 2
    local cy = oy + plot_size / 2
    local scale = plot_size / 2 * 0.85

    draw.filled_rect(ox, oy, plot_size, plot_size, 0xCC000000)
    draw.outline_rect(ox, oy, plot_size, plot_size, 0xFF888888)
    draw.line(ox, cy, ox + plot_size, cy, 0x44FFFFFF)
    draw.line(cx, oy, cx, oy + plot_size, 0x44FFFFFF)
    draw.outline_circle(cx, cy, scale, 0x44FFFFFF, 32)

    if raw_x ~= 0 or raw_y ~= 0 then
        local rx = cx - raw_x * scale
        local ry = cy - raw_y * scale
        draw.filled_circle(rx, ry, 5, 0xFFFFFF44, 16)
        draw.text(string.format("Raw(%.2f)", math.sqrt(raw_x * raw_x + raw_y * raw_y)), rx - 16, ry + 6, 0xFFFFFF44)

        if config.enabled then
            local fx = cx - out_x * scale
            local fy = cy - out_y * scale
            draw.line(rx, ry, fx, fy, 0xAAFFFFFF)
            draw.filled_circle(fx, fy, 5, 0xFF44FF44, 16)
            draw.text(string.format("Out(%.2f)", math.sqrt(out_x * out_x + out_y * out_y)), fx - 16, fy + 6, 0xFF44FF44)
        end
    end

    local cx_center = ox + plot_size / 2
    local dz = effective_dz()
    local label = config.mode == 1 and string.format("DZ: %.3f | Pow: %.2f", dz, config.curve_power) or
                      string.format("DZ: %.3f", dz)
    local speed_text = string.format("Speed: %.3f, %.3f", out_x, out_y)
    draw.text(label, cx_center - imgui.calc_text_size(label).x / 2, oy + plot_size + 4, 0xFF00FF00)
    draw.text(speed_text, cx_center - imgui.calc_text_size(speed_text).x / 2, oy + plot_size + 18, 0xFF88FF88)

    -- Curve graph (bottom-right corner)
    local cgx = ox + plot_size - 64
    local cgy = oy + plot_size - 64
    local cgs = 60
    draw.outline_rect(cgx - 2, cgy - 2, cgs + 4, cgs + 4, 0x88FFFFFF)
    draw.filled_rect(cgx, cgy, cgs, cgs, 0x66000000)
    draw.line(cgx, cgy + cgs, cgx + cgs, cgy + cgs, 0x44FFFFFF)
    draw.line(cgx, cgy + cgs, cgx, cgy, 0x44FFFFFF)

    local function curve_fn(t, dz)
        if t <= dz then
            return 0
        end
        local r = (t - dz) / (1.0 - dz)
        if config.mode == 1 then
            return r ^ config.curve_power
        else
            return r
        end
    end

    local curve_dz = effective_dz()
    local prev_x, prev_y
    for i = 0, cgs do
        local t = i / cgs
        local out = curve_fn(t, curve_dz)
        local px = cgx + i
        local py = cgy + cgs - out * cgs
        if prev_x then
            draw.line(prev_x, prev_y, px, py, 0xFFFFFF88)
        end
        prev_x, prev_y = px, py
    end

    -- Mark the current raw magnitude position on the curve
    if raw_x ~= 0 or raw_y ~= 0 then
        local raw_mag = math.sqrt(raw_x * raw_x + raw_y * raw_y)
        local raw_clamped = raw_mag > 1.0 and 1.0 or raw_mag
        local mx = cgx + raw_clamped * cgs
        local my = cgy + cgs - curve_fn(raw_clamped, curve_dz) * cgs
        draw.filled_circle(mx, my, 3, 0xFF44FF44, 8)
    end
end)
