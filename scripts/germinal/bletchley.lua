-- Bletchley Park
-- 2 voice x 3 bit shift register
-- with or without grid, midi capable
--
-- enc1: bpm
-- enc2: pulse division (24ppqn base, default 2)
-- enc3: voice 1 trigger probability
-- key2: start/stop
-- key3: next UI page
-- 
-- voices default to midi channels 1 and 2
-- (use 3 and 4 for cvpal)

beatclock = require 'beatclock'

engine.name = 'PolyPerc'
function midi_to_hz(note)
  return (440/32) * (2 ^ ((note - 9) / 12))
end

local page = 1

local voices = {
  {channel=3, range=2, offset=35, prob=8, accum=1, accumulator=0, gate_time=0.35, off_metro=metro.alloc()},
  {channel=4, range=3, offset=35, prob=1, accum=1, accumulator=0, gate_time=0.35, off_metro=metro.alloc()}
}

local clock_divide = 2

local g -- grid
local m -- midi

local clk = beatclock.new()
clk.steps_per_beat = clock_divide
clk:bpm_change(clk.bpm)
local started = false

local pulse_on = metro.alloc()
pulse_on.time = 0.1
pulse_on.count = -1

local pulse_off = metro.alloc()
pulse_off.time = 0.35
pulse_off.count = 1

local factor = 0
local factor_cutoff = 5

local loop_length = 5

local circle_of_fifths = {
  {n=0, name="C"}, {n=7, name="G"}, {n=2, name="D"}, {n=9, name="A"}, 
  {n=4, name="E"}, {n=11, name="B"}, {n=6, name="F#"}, {n=1, name="C#"}, 
  {n=8, name="G#"}, {n=3, name="E#"}, {n=10, name="A#"}, {n=5, name="F"}
}

local circle_of_fifths_labels = {}
for l = 1,#circle_of_fifths do 
  circle_of_fifths_labels[l] = circle_of_fifths[l].name
end

local scales = {
  {name="CHROMATIC", scale={0,1,2,3,4,5,6,7,8,9,10,11, 12}},
  {name="DIATONIC", scale={0,2,4,5,7,9,11, 12}},
  {name="PENTATONIC", scale={0,3,5,7,9,12}},
  {name="ONEFOURFIVE", scale={0,5,7,12}},
  {name="ONEFIVE", scale={0,7,12}},
  {name="OCTAVE", scale={0,12}}
}

local scale_labels = {}
for s = 1, #scales do
  scale_labels[s] = scales[s].name
end

local trigger_prob_table = {
  0,
  1,
  3,
  5,
  8,
  11,
  15,
  16
}

local range_options = {
  2,3,4,5
}

local offset_options = {
  12,24,36,42,48,54,60,66,72
}

-- Set up 16 registers, with a value from 1-8
local MAX_STEP = 16
local current_step = MAX_STEP
local registers = {}
for i = 1,MAX_STEP do
  registers[i] = 1
end

-- default values for unselected grid cells in page
local g_default_exp = {
  {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
  {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
  {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
  {1,2,3,4,5,6,7,8,1,2,3,4,5,6,7,8},
  {1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8},
  {2,3,4,5,0,0,0,0,0,0,0,0,2,3,4,5},
  {2,3,4,5,6,7,8,9,2,3,4,5,6,7,8,9},
  {2,2,2,2,2,2,2,2,2,2,2,2,6,6,0,5}
}

-- simple quantizer, could use some love
function to_scale(raw_n)
  local scale_offsets = scales[params:get("scale")].scale
  local scale_root = circle_of_fifths[params:get("root")].n
  local n = raw_n - scale_root
  local pitch_class = n % 12
  local octave = math.floor(n / 12)
  local rounded = 0
  for offset=1,6 do
    if pitch_class < scale_offsets[offset] then
      rounded = scale_offsets[offset - 1]
      -- print("rounded to " .. rounded)
      break
    end
  end
  local output = scale_root + rounded + (12 * octave)

  return output
end


-- utilities for viewing the register as 3 binary digits
function hi_bit(n) 
  if n == 8 then return 1
  elseif n == 7 then return 1
  elseif n == 6 then return 1
  elseif n == 5 then return 1
  else return 0
  end
end

function mid_bit(n)
  if n == 8 then return 1
  elseif n == 7 then return 1
  elseif n == 3 then return 1
  elseif n == 4 then return 1
  else return 0
  end
end

function lo_bit(n)
  if n == 8 then return 1
  elseif n == 2 then return 1
  elseif n == 4 then return 1
  elseif n == 6 then return 1
  else return 0
  end
end

function get_next_step()
  local next_step = current_step + 1
  if next_step > MAX_STEP then
    next_step = 1
  end
  return next_step
end

-- in page 0, directly draw the register values 1-8 onto the grid
function redraw_grid_page0()
  local next_step = get_next_step()
  print("redraw_grid_page0")
  
  for i=1,MAX_STEP do 
    for j=1,8 do
      if (registers[i] == j) then
        g.led(i, 9 - j, 10)
      elseif next_step == i then
        g.led(i, 9 - j, 1)
      else 
        g.led(i, 9 - j, 0)
      end
    end
  end
  g.refresh()
end

-- in page 1, draw the registers in binary to the top 3 rows, use the bottom 5 for UI
function redraw_grid_page1()
  local next_step = get_next_step()
  -- print("redraw_grid_expert")
  local r = registers
  for i=1,MAX_STEP do
    -- row 1 - high bit - value of 4
    if hi_bit(r[i]) == 1 then
      g.led(i, 1, 6)
    elseif next_step == i then
      g.led(i, 1, 2)
    else 
      g.led(i, 1, 0)
    end
    
    -- row 2 - middle bit - value of 2
    if mid_bit(r[i]) == 1 then
      g.led(i, 2, 6)
    elseif next_step == i then
      g.led(i, 2, 2)
    else 
      g.led(i, 2, 0)
    end

    -- row 3 - low bit - value of 1
    if lo_bit(r[i]) == 1 then
      g.led(i, 3, 6)
    elseif next_step == i then
      g.led(i, 3, 2)
    else
      g.led(i, 3, 0)
    end

    for j=4,8 do
      -- row 4 - trigger prob voice 1/2
      if j == 4 then
        if (i < 9) and ( i == voices[1].prob) then
            g.led(i,j,15)
        elseif ( (i - 8) == voices[2].prob) then
            g.led(i,j,15)
        else
            g.led(i,j,g_default_exp[j][i])        
        end
      -- row 5 - loop length
      elseif j == 5 then
        if i == loop_length then
          g.led(i,j,15)
        else
          g.led(i,j,g_default_exp[j][i])
        end
      -- row 6 -- voice 1 range / chance / voice 2 range
      elseif j == 6  then
        if i < 5 and ( i == params:get("voice_1_pitch_range")) then
          g.led(i,j,15)
        elseif i >= 5 and i < 12 and (factor_cutoff == (i - 4)) then
          g.led(i,j,15)
        elseif i >= 13 and ( i - 12 == params:get("voice_2_pitch_range")) then
          g.led(i,j,15)
        else
          g.led(i,j,g_default_exp[j][i])        
          
        end
      -- row 7 -- voice 1 offset / voice 2 offset
      elseif j == 7 then
        if (i < 9) and ( i == params:get("voice_1_pitch_offset")) then
          g.led(i,j,15)
        elseif ( (i - 8) == params:get("voice_2_pitch_offset")) then
          g.led(i,j,15)
        else
          g.led(i,j,g_default_exp[j][i])        
        end
      -- row 8 -- key (circle of fifths) / scale / start/stop
      elseif j == 8 then
        if (i) == params:get("root") then
          g.led(i,j,6)
        else
          g.led(i,j,g_default_exp[j][i])
        end
      else 
        g.led(i,j,g_default_exp[j][i])
      end
    end
  end
  g.refresh()
end

function redraw_grid() 
  if page == 1 then
    redraw_grid_page1()
  else
    redraw_grid_page0()
  end
end

function g_event_page0(x,y,z)
  local val = 9 - y
  print("grid - x: " .. x .. " y: " .. y .. " z: " .. z .. " VALUE: " .. 9 - y)
  registers[x] = val
  redraw_grid()
end

function g_event_page1(x,y,z)
  print("grid - x: " .. x .. " y: " .. y .. " z: " .. z .. " VALUE: " .. 9 - y)
  if x == 16 and y == 8 and z == 1 then
    toggle_clock()
  elseif y == 1 and z == 1 then
    if hi_bit(registers[x]) == 1 then
      registers[x] = registers[x] - 4
    else
      registers[x] = registers[x] + 4
    end
  elseif y == 2 and z == 1 then
    if mid_bit(registers[x]) == 1 then
      registers[x] = registers[x] - 2
    else
      registers[x] = registers[x] + 2
    end
  elseif y == 1 and z == 1 then
    if low_bit(registers[x]) == 1 then
      registers[x] = registers[x] - 1
    else
      registers[x] = registers[x] + 1
    end
  elseif y == 4 and z == 1 and x < 9 then
    params:set("voice_1_trigger_prob", x)
  elseif y == 4 and z == 1 and x >= 9 then
    params:set("voice_2_trigger_prob", x - 8)
  elseif y == 5 and z == 1 then
    params:set("loop_length", x)
  elseif y == 6 and z == 1 and x <= 4 then
    params:set("voice_1_pitch_range", x)
  elseif y == 6 and z == 1 and x > 4 and x < 13 then
    params:set("chance", x - 4)
  elseif y == 6 and z == 1 and x >= 13 then
    params:set("voice_2_pitch_range", x - 12)
  elseif y == 7 and z == 1 and x < 9 then
    params:set("voice_1_pitch_offset", x)
  elseif y == 7 and z == 1 and x >= 9 then
    params:set("voice_2_pitch_offset", x - 8)
  elseif y == 8 and z == 1 and x < 13 then
    params:set("root", x)
  end
  redraw()
  redraw_grid()
end

function init()
  g = grid.connect()
  g.event = function(x,y,z)
    if page == 0 then
      g_event_page0(x,y,z)
    else
      g_event_page1(x,y,z)
    end
  end

  m = midi.connect(1)
  m.event = function(data) 
    return  
  end
  print(dump(m))
  --midi panic on startup
  for i = 1,128 do
    m.note_off(i,0,voices[1].channel)
    m.note_off(i,0,voices[2].channel)
  end

  pulse_on.callback = on_pulse
  params:add_number("chance","chance",1,8,5)
  params:set_action("chance", function(x) factor_cutoff = x end)

  params:add_number("loop_length", "loop_length",1,16,5)
  params:set_action("loop_length", function(x) loop_length = x end)

  params:add_option("scale", "scale", scale_labels)
  params:set("scale",3)
  params:set_action("scale", function(x) print("selected scale " .. x) end)
  
  params:add_option("root", "root", circle_of_fifths_labels)
  params:set("root",1)
  params:set_action("root", function(x) print("selected root " .. x) end)

  params:add_trigger("clock_tog", "clock_tog", 0,1,0)
  params:set_action("clock_tog", function() toggle_clock() end)
  
  params:add_number("clock_divide", "clock_divide", 1, 8, 2)
  params:set_action("clock_divide", function(x) 
    clock_divide = x 
    clk.steps_per_beat = clock_divide
    clk:bpm_change(clk.bpm)
  end)

  clk.on_step = on_pulse
  clk.on_select_internal = function() print("internal clock") end
  clk.on_select_external = function() print("external clock") end
  clk:add_clock_params()
  
  local voice_params = {
    {name="pitch_range", min=0, max=8, default=5},
    {name="pitch_offset", min=0, max=60, default=15},
    {name="trigger_prob", min=1, max=16, default=1},
  }
  
  for voice=1,#voices do 
    params:add_separator()
    params:add_number("voice_"..voice.."_midi_channel","voice_"..voice.."_midi_channel",0,16,1)
    params:set_action("voice_"..voice.."_midi_channel", function(x) voices[voice].channel = x end)

    params:add_option("voice_"..voice.."_pitch_range","voice_"..voice.."_pitch_range", range_options)
    params:set("voice_"..voice.."_pitch_range",3)
    params:set_action("voice_"..voice.."_pitch_range", function(x) voices[voice].range = range_options[x] end)

    params:add_option("voice_"..voice.."_pitch_offset","voice_"..voice.."_pitch_offset", offset_options)
    params:set("voice_"..voice.."_pitch_offset",4)
    params:set_action("voice_"..voice.."_pitch_offset", function(x) voices[voice].offset = offset_options[x] end)

    params:add_number("voice_"..voice.."_trigger_prob","voice_"..voice.."_trigger_prob",1,8,8)
    params:set_action("voice_"..voice.."_trigger_prob", function(x) voices[voice].prob = x end)
  end

  redraw()
  redraw_grid()
end

function toggle_clock()
  if started then
    clk:stop()
    started = false
  else 
    clk:start()
    started = true
  end
end


function key(n,z)
  if z == 1 and n == 2 then
    toggle_clock()
  elseif z == 1 and n == 3 then
    if page == 0 then
      page = 1
    else 
      page = 0
    end
    redraw()
    redraw_grid()
  end
end

function enc(n,d)
  if n == 1 then
    params:delta("bpm",d)
  elseif n == 2 then
    params:delta("clock_divide", d)
  elseif n == 3 then
    params:delta("voice_1_trigger_prob",d)
    redraw()
  end
end

function make_next_note() 

  local next_step = current_step + 1
  local loop_step = ((current_step - loop_length) % MAX_STEP) + 1 -- hmmm

  if next_step > MAX_STEP then
    next_step = 1
  end
  
  chance_random = math.random(8)
  if chance_random > factor_cutoff then
    registers[next_step] = math.random(8)
  else
    registers[next_step] = registers[loop_step]
  end
  
  redraw_grid()
  redraw()
  local output = make_raw_note(next_step)
  
  current_step = current_step + 1 
  if current_step > MAX_STEP then
    current_step = 1
  end
  return math.floor(output)
  
end

function make_raw_note(i) 
  local output = 0
  for j = 0,7 do
    local weight = math.pow(2,3 - j)
    local this_step = (i - j) 
    if this_step <= 0 then
      this_step = this_step + 16
    end
    output = output + (weight * (registers[this_step] - 1))
  end
  return output
end

last_note = nil

function on_pulse()
  local next_note_raw = make_next_note()
  for voice=1,#voices do
    trigger_random = math.random(16)
    if trigger_random <= trigger_prob_table[voices[voice].prob] then
      local ranged = ((next_note_raw / 112) * (12 * voices[voice].range )) + voices[voice].offset
      local scaled = to_scale(ranged) 
      engine.hz(midi_to_hz(scaled))
      m.note_on(scaled, 100, voices[voice].channel)
      voices[voice].off_metro.callback = make_off_pulse(scaled,voices[voice].channel)
      voices[voice].off_metro:start()
    end
  end
end

function make_off_pulse(note,chan)
  function f()
    m.note_off(note,0,chan)
  end
end

function off_pulse()
  if last_note then
    m.note_on(last_note,0,1)
    last_note = nil
  end
end

function draw_ui_page1()
  screen.clear()
  screen.move(0,30)
  screen.text("LENGTH: "..params:get("loop_length") .. " BPM " .. params:get("bpm") .. " DIV " .. params:get("clock_divide"))
  screen.move(0,38)
  screen.text("CHANGE: "..params:get("chance") .. " PROB 1:" .. params:get("voice_1_trigger_prob") .. " 2:".. params:get("voice_2_trigger_prob"))
  screen.move(0,46)
  screen.text("V:OFFST/RNG: 1:" .. offset_options[params:get("voice_1_pitch_offset")] .. "/" .. range_options[params:get("voice_1_pitch_range")] .. " 2:" ..  offset_options[params:get("voice_2_pitch_offset")] .. "/" .. range_options[params:get("voice_2_pitch_range")]  )
  screen.move(0,54)
  screen.text("SCALE: " .. circle_of_fifths[params:get("root")].name .. " " .. scales[params:get("scale")].name )
  screen.move(0,62)
  screen.text("PUSH 2: START/STOP  3: PAGE 0")
  local r = registers
  for i=1,16 do
    local hi = hi_bit(r[i])
    local mid = mid_bit(r[i])
    local lo = lo_bit(r[i])
  
    local rect_off = ( i - 1) * 8
    if hi == 1 then
      screen.rect(rect_off, 0,5, 5)
      screen.fill()
    else 
      screen.rect(1 + rect_off, 1, 4, 4)
      screen.stroke()
    end
    if mid == 1 then
      screen.rect(rect_off, 6, 5, 5)
      screen.fill()
    else 
      screen.rect(1 + rect_off, 7, 4, 4)
      screen.stroke()
    end
    if lo == 1 then
      screen.rect(rect_off, 12, 5, 5)
      screen.fill()
    else 
      screen.rect(1 + rect_off, 13, 4, 4)
      screen.stroke()
    end

  end
  screen.stroke()
  screen.update()

end

function draw_ui_page0()
  screen.clear()
  screen.move(0,62)
  screen.text("PUSH 2: START/STOP  3: PAGE 1")
  local r = registers
  for i=1,16 do 
    local rect_off = ( (i - 1) * 8)
    for j=0,7 do
      if (8 - j) == r[i] then
        screen.rect(rect_off,1 + (j * 6), 5,5)
        screen.fill()
        
      else
        screen.rect(rect_off + 1,2 + (j * 6), 4,4)
        screen.stroke()
      end
    end
    local next_step = get_next_step()
    screen.move (1 + ((next_step - 1) * 8) ,55)
    screen.text("^")
  end
  screen.stroke()
  screen.update()
end

function redraw()
  if page == 1 then
    draw_ui_page1()
  else
    draw_ui_page0()
  end
end

function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end
