-- Dragon's Dogma 2 Controller Diagonal Camera Fix
-- Two modes: Linear or Power Curve (magnitude-based, angle-preserving).

local config = json.load_file("ControllerDiagonalFix.json") or {}
if config.mode == nil then config.mode = 0 end
if config.dead_zone == nil then config.dead_zone = 0.15 end

if config.curve_power == nil then config.curve_power = 1.5 end
if config.show_debug == nil then config.show_debug = true end
if config.enabled == nil then config.enabled = true end

local function save_settings()
    json.dump_file("ControllerDiagonalFix.json", config)
end

local raw_x, raw_y = 0, 0
local out_x, out_y = 0, 0
local call_count = 0
local prev_y = 0

local dbg_output_rate = 0
local linear_out = 0

local display_w, display_h = 1920, 1080

-- Auto calibration: tracks game_rate transitions to find dead zone
local auto_cal = true
local cal_detected = 1.0
local cal_frame_moving = false
local cal_frame_mag = 0

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
local function apply_linear_dz(axis_val, other_val, dz)
    local mag = math.sqrt(axis_val * axis_val + other_val * other_val)
    if mag <= dz then return 0 end
    local f = (mag - dz) / (1.0 - dz) / mag
    return axis_val * f
end

-- Power curve on magnitude (angle-preserving), with dead zone
local function apply_power_curve(axis_val, other_val, dz)
    local mag = math.sqrt(axis_val * axis_val + other_val * other_val)
    if mag <= dz then return 0 end
    local remapped = (mag - dz) / (1.0 - dz)
    local cm = (remapped ^ config.curve_power) / mag
    return axis_val * cm
end

local method = sdk.find_type_definition("app.RotateCameraControllerBase"):get_method("getInputRotationSpeedRate")

sdk.hook(
    method,
    function(args)
        local raw = sdk.to_float(args[3]) or 0

        local cam = sdk.to_managed_object(args[2])
        if not cam then return sdk.PreHookResult.CALL_ORIGINAL end

        local is_mouse = false
        local ok, v = pcall(function() return cam:get_IsMouseMovedInFrame() end)
        if ok then is_mouse = v end

        if is_mouse then
            linear_out = raw
            return sdk.PreHookResult.CALL_ORIGINAL
        end

        call_count = call_count + 1

        -- Accumulate frame magnitude for calibration (at call 2 we have both axes)
        if call_count == 1 then
            raw_x = raw
        elseif call_count == 2 then
            raw_y = raw
            cal_frame_mag = math.sqrt(raw_x * raw_x + raw_y * raw_y)
        end

        if config.enabled then
            local other = (call_count == 1) and prev_y or raw_x
            local dz = effective_dz()

            if config.mode == 0 then
                linear_out = apply_linear_dz(raw, other, dz)
            else
                linear_out = apply_power_curve(raw, other, dz)
            end

            if call_count == 1 then
                out_x = linear_out
            elseif call_count == 2 then
                out_y = linear_out
            end

            args[3] = sdk.float_to_ptr(raw)
        else
            linear_out = raw
            if call_count == 1 then
                out_x = raw
            elseif call_count == 2 then
                out_y = raw
            end
        end

        return sdk.PreHookResult.CALL_ORIGINAL
    end,
    function(retval)
        local rate = sdk.to_float(retval) or 0
        dbg_output_rate = rate

        -- Track if game considers this frame "moving"
        if math.abs(rate) > 0.001 then
            cal_frame_moving = true
        end

        if config.enabled then
            return sdk.float_to_ptr(linear_out)
        end
        return retval
    end
)

re.on_frame(function()
    -- Auto-calibrate: track minimum magnitude across ALL frames where game detects movement
    if auto_cal and cal_frame_moving and cal_frame_mag > 0 then
        if cal_frame_mag < cal_detected then
            cal_detected = cal_frame_mag
        end
    end
    prev_y = raw_y
    call_count = 0
    cal_frame_moving = false
    cal_frame_mag = 0
end)

re.on_draw_ui(function()
    local ds = imgui.get_display_size()
    if ds then display_w, display_h = ds.x, ds.y end
    if not imgui.collapsing_header("Controller Diagonal Fix") then return end

    local c1, v1 = imgui.checkbox("Enabled", config.enabled)
    if c1 then config.enabled = v1; save_settings() end

    imgui.set_next_item_width(imgui.calc_text_size("Power Curve").x + 36)
    local cm, nm = imgui.combo("Mode", config.mode + 1, { "Linear", "Power Curve" })
    if cm then
        config.mode = nm - 1; save_settings()
    end
    info_icon("Linear: scales stick input linearly from dead zone to 1.0.\nPower Curve: applies an exponential curve for finer low-speed control and sharper highs.")

    if config.mode == 1 then
        local c4, v4 = imgui.slider_float("Curve power", config.curve_power, 1.0, 3.0, "%.2f")
        if c4 then config.curve_power = v4; save_settings() end
        info_icon("Higher values = more stick output at high tilt, less at low tilt.\n1.0 = linear, 2.0 = quadratic, 3.0 = cubic.")
    end

    local c2, v2 = imgui.checkbox("Detect Dead Zone Automatically", auto_cal)
    if c2 then auto_cal = v2 end
    info_icon("Tracks the minimum stick movement the game registers and uses it as the dead zone.\nThreshold shows the current detected minimum.")
    imgui.same_line()
    imgui.text(string.format("Threshold: %.3f", cal_detected))
    if not auto_cal then
        local c3, v3 = imgui.slider_float("Dead zone", config.dead_zone, 0.0, 0.40, "%.3f")
        if c3 then config.dead_zone = v3; save_settings() end
        info_icon("Manual dead zone. Stick input below this value is ignored.\nOnly used when Detect Dead Zone is off.")
    end

    local c3, v3 = imgui.checkbox("Show Debug", config.show_debug)
    if c3 then config.show_debug = v3; save_settings() end
    info_icon("Shows a 2D stick overlay (centered) and a curve graph (bottom-right)\nwith raw input, output, dead zone, and speed readouts.")

    if config.show_debug then
        local dz = effective_dz()
        local extra = config.mode == 1 and string.format(" | Pow: %.2f", config.curve_power) or ""
        imgui.text(string.format("Raw: %.3f, %.3f | Out: %.3f, %.3f | DZ: %.3f%s", raw_x, raw_y, out_x, out_y, dz, extra))
        imgui.text(string.format("Game rate: %.4f", dbg_output_rate))
    end
end)

re.on_frame(function()
    if not config.show_debug then return end

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
        draw.text(string.format("Raw(%.2f)", math.sqrt(raw_x*raw_x + raw_y*raw_y)), rx - 16, ry + 6, 0xFFFFFF44)

        if config.enabled then
            local fx = cx - out_x * scale
            local fy = cy - out_y * scale
            draw.line(rx, ry, fx, fy, 0xAAFFFFFF)
            draw.filled_circle(fx, fy, 5, 0xFF44FF44, 16)
            draw.text(string.format("Out(%.2f)", math.sqrt(out_x*out_x + out_y*out_y)), fx - 16, fy + 6, 0xFF44FF44)
        end
    end

    local cx_center = ox + plot_size / 2
    local dz = effective_dz()
    local label = config.mode == 1 and string.format("DZ: %.3f | Pow: %.2f", dz, config.curve_power) or string.format("DZ: %.3f", dz)
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
        if t <= dz then return 0 end
        local r = (t - dz) / (1.0 - dz)
        if config.mode == 1 then return r ^ config.curve_power
        else return r end
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
