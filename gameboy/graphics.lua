local memory = require("gameboy/memory")

local graphics = {}

-- Initialize VRAM blocks in main memory
-- TODO: Implement access restrictions here based
-- on the Status register
local vram = memory.generate_block(8 * 1024)
memory.map_block(0x80, 0x9F, vram)
local oam = memory.generate_block(0xA0)
oam = {}
oam.mt = {}
oam.mt.__index = function(table, address)
  -- out of range? So sorry, return nothing
  return 0x00
end
oam.mt.__newindex = function(table, address, byte)
  -- out of range? So sorry, discard the write
  return
end
setmetatable(oam, oam.mt)
memory.map_block(0xFE, 0xFE, oam)

-- Various functions for manipulating IO in memory
local LCDC = function()
  return io.ram[0x40]
end

local STAT = function()
  return io.ram[0x41]
end

local setSTAT = function(value)
  io.ram[0x41] = value
end

local LCD_Control = {}
graphics.LCD_Control = LCD_Control
LCD_Control.DisplayEnabled = function()
  return bit32.band(0x80, LCDC()) ~= 0
end

LCD_Control.WindowTilemap = function()
  if bit32.band(0x40, LCDC()) ~= 0 then
    return 0x9C00
  else
    return 0x9800
  end
end

LCD_Control.WindowEnabled = function()
  return bit32.band(0x20, LCDC()) ~= 0
end

LCD_Control.TileData = function()
  if bit32.band(0x10, LCDC()) ~= 0 then
    return 0x8000
  else
    return 0x9000
  end
end

LCD_Control.BackgroundTilemap = function()
  if bit32.band(0x08, LCDC()) ~= 0 then
    return 0x9C00
  else
    return 0x9800
  end
end

LCD_Control.LargeSprites = function()
  return bit32.band(0x04, LCDC()) ~= 0
end

LCD_Control.SpritesEnabled = function()
  return bit32.band(0x02, LCDC()) ~= 0
end

LCD_Control.BackgroundEnabled = function()
  return bit32.band(0x01, LCDC()) ~= 0
end

local Status = {}
graphics.Status = Status
Status.Coincidence_InterruptEnabled = function()
  return bit32.band(0x20, STAT()) ~= 0
end

Status.OAM_InterruptEnabled = function()
  return bit32.band(0x10, STAT()) ~= 0
end

Status.VBlank_InterruptEnabled = function()
  return bit32.band(0x08, STAT()) ~= 0
end

Status.HBlank_InterruptEnabled = function()
  return bit32.band(0x06, STAT()) ~= 0
end

Status.Mode = function()
  return bit32.band(io.ram[0x41], 0x3)
end

graphics.vblank_count = 0

Status.SetMode = function(mode)
  io.ram[0x41] = bit32.band(STAT(), 0xF8) + bit32.band(mode, 0x3)
  if mode == 0 then
    -- HBlank
    graphics.draw_scanline(graphics.scanline())
  end
  if mode == 1 then
    if LCD_Control.DisplayEnabled() then
      -- VBlank
      --draw_screen()
      graphics.vblank_count = graphics.vblank_count + 1
    else
      --clear_screen()
    end
  end
end

local SCY = function()
  return io.ram[0x42]
end

local SCX = function()
  return io.ram[0x43]
end

local WY = function()
  return io.ram[0x4A]
end

local WX = function()
  return io.ram[0x4B]
end

graphics.scanline = function()
  return io.ram[0x44]
end

graphics.set_scanline = function(value)
  io.ram[0x44] = value
end

graphics.scanline_compare = function()
  return io.ram[0x45]
end

local last_edge = 0

local time_at_this_mode = function()
  return clock - last_edge
end

-- HBlank: Period between scanlines
local handle_mode = {}
handle_mode[0] = function()
  if clock - last_edge > 204 then
    last_edge = last_edge + 204
    graphics.set_scanline(graphics.scanline() + 1)
    -- If enabled, fire an HBlank interrupt
    if bit32.band(STAT(), 0x08) ~= 0 then
      request_interrupt(Interrupt.LCDStat)
    end
    if graphics.scanline() == graphics.scanline_compare() then
      -- set the LY compare bit
      setSTAT(bit32.bor(STAT(), 0x4))
      if bit32.band(STAT(), 0x40) ~= 0 then
        request_interrupt(Interrupt.LCDStat)
      end
    else
      -- clear the LY compare bit
      setSTAT(bit32.band(STAT(), 0xFB))
    end
    if graphics.scanline() >= 144 then
      Status.SetMode(1)
      request_interrupt(Interrupt.VBlank)
      if bit32.band(STAT(), 0x10) ~= 0 then
        -- This is weird; LCDStat mirrors VBlank?
        request_interrupt(Interrupt.LCDStat)
      end
      -- TODO: Draw the real screen here?
    else
      Status.SetMode(2)
      if bit32.band(STAT(), 0x20) ~= 0 then
        request_interrupt(Interrupt.LCDStat)
      end
    end
  end
end

--VBlank: nothing to do except wait for the next frame
handle_mode[1] = function()
  if clock - last_edge > 456 then
    last_edge = last_edge + 456
    graphics.set_scanline(graphics.scanline() + 1)
  end
  if graphics.scanline() >= 154 then
    graphics.set_scanline(0)
    Status.SetMode(2)
    if bit32.band(STAT(), 0x20) ~= 0 then
      request_interrupt(Interrupt.LCDStat)
    end
  end
  if graphics.scanline() == graphics.scanline_compare() then
    -- TODO: fire LCD STAT interrupt, and set appropriate flag
  end
end

-- OAM Read: OAM cannot be accessed
handle_mode[2] = function()
  if clock - last_edge > 80 then
    last_edge = last_edge + 80
    Status.SetMode(3)
  end
end
-- VRAM Read: Neither VRAM, OAM, nor CGB palettes can be read
handle_mode[3] = function()
  if clock - last_edge > 172 then
    last_edge = last_edge + 172
    Status.SetMode(0)
    -- TODO: Fire HBlank interrupt here!!
    -- TODO: Draw one scanline of graphics here!
  end
end

graphics.initialize = function()
  Status.SetMode(2)
end

graphics.update = function()
  if LCD_Control.DisplayEnabled() then
    handle_mode[Status.Mode()]()
  else
    -- erase our clock debt, so we don't do stupid timing things when the
    -- display is enabled again later
    last_edge = clock
  end
end

-- TODO: Handle proper color palettes?
local colors = {}
colors[0] = {255, 255, 255}
colors[1] = {192, 192, 192}
colors[2] = {128, 128, 128}
colors[3] = {0, 0, 0}

graphics.game_screen = {}
for y = 0, 143 do
  graphics.game_screen[y] = {}
  for x = 0, 159 do
    graphics.game_screen[y][x] = {255, 255, 255}
  end
end

local function plot_pixel(buffer, x, y, r, g, b)
  buffer[y][x][1] = r
  buffer[y][x][2] = g
  buffer[y][x][3] = b
end

local function debug_draw_screen()
  for i = 0, 143 do
    graphics.draw_scanline(i)
  end
end

graphics.getColorFromTile = function(tile_address, subpixel_x, subpixel_y, palette)
  palette = palette or 0xE4
  -- move to the row we need this pixel from
  while subpixel_y > 0 do
    tile_address = tile_address + 2
    subpixel_y = subpixel_y - 1
  end
  -- grab the pixel color we need, and translate it into a palette index
  local palette_index = 0
  if bit32.band(vram[tile_address - 0x8000], bit32.lshift(0x1, 7 - subpixel_x)) ~= 0 then
    palette_index = palette_index + 1
  end
  tile_address = tile_address + 1
  if bit32.band(vram[tile_address - 0x8000], bit32.lshift(0x1, 7 - subpixel_x)) ~= 0 then
    palette_index = palette_index + 2
  end
  -- finally, return the color from the table, based on this index
  -- todo: allow specifying the palette?
  while palette_index > 0 do
    palette = bit32.rshift(palette, 2)
    palette_index = palette_index - 1
  end
  return colors[bit32.band(palette, 0x3)]
end

graphics.getColorFromTilemap = function(map_address, x, y)
  local tile_x = bit32.rshift(x, 3)
  local tile_y = bit32.rshift(y, 3)
  local tile_index = vram[(map_address + (tile_y * 32) + (tile_x)) - 0x8000]
  if tile_index == nil then
    print(tile_x)
    print(tile_y)
    print(map_address)
    print((map_address + (tile_y * 32) + (tile_x)) - 0x8000)
  end
  if LCD_Control.TileData() == 0x9000 then
    if tile_index > 127 then
      tile_index = tile_index - 256
    end
  end
  local tile_address = LCD_Control.TileData() + tile_index * 16

  local subpixel_x = x - (tile_x * 8)
  local subpixel_y = y - (tile_y * 8)

  return graphics.getColorFromTile(tile_address, subpixel_x, subpixel_y, io.ram[0x47])
end

-- local oam = 0xFE00

local function draw_sprites_into_scanline(scanline)
  local active_sprites = {}
  local sprite_size = 8
  if LCD_Control.LargeSprites() then
    sprite_size = 16
  end

  -- Collect up to the 10 highest priority sprites in a list.
  -- Sprites have priority first by their X coordinate, then by their index
  -- in the list.
  local i = 0
  while i < 40 do
    -- is this sprite being displayed on this scanline? (respect to Y coordinate)
    local sprite_y = oam[i * 4]
    local sprite_lower = sprite_y - 16
    local sprite_upper = sprite_y - 16 + sprite_size
    if scanline >= sprite_lower and scanline < sprite_upper then
      if #active_sprites < 10 then
        table.insert(active_sprites, i)
      else
        -- There are more than 10 sprites in the table, so we need to pick
        -- a candidate to vote off the island (possibly this one)
        local lowest_priority = i
        local lowest_priotity_index = nil
        for j = 1, #active_sprites do
          local lowest_x = oam[lowest_priority * 4 + 1]
          local candidate_x = oam[active_sprites[j] * 4 + 1]
          if candidate_x > lowest_x then
            lowest_priority = active_sprites[j]
            lowest_priority_index = j
          end
        end
        if lowest_priority_index then
          active_sprites[lowest_priority_index] = i
        end
      end
    end
    i = i + 1
  end

  -- now, for every sprite in the list, display it on the current scanline
  for i = #active_sprites, 1, -1 do
    local sprite_address = active_sprites[i] * 4
    local sprite_y = oam[sprite_address]
    local sprite_x = oam[sprite_address + 1]
    local sprite_tile = oam[sprite_address + 2]
    if sprite_size == 16 then
      sprite_tile = bit32.band(sprite_tile, 0xFE)
    end
    local sprite_flags = oam[sprite_address + 3]

    local sub_y = 16 - (sprite_y - scanline)

    local sprite_palette = io.ram[0x48]
    if bit32.band(sprite_flags, 0x10) ~= 0 then
      sprite_palette = io.ram[0x49]
    end

    local start_x = math.max(0, sprite_x - 8)
    local end_x = math.min(159, sprite_x)
    local x = start_x
    while x < end_x do
      local subpixel_color = graphics.getColorFromTile(0x8000 + sprite_tile * 16, x - sprite_x + 8, sub_y, sprite_palette)
      plot_pixel(graphics.game_screen, x, scanline, unpack(subpixel_color))
      x = x + 1
    end
  end
  if #active_sprites > 0 then
  end
end

graphics.draw_scanline = function(scanline)
  local bg_y = scanline + SCY()
  local bg_x = SCX()
  -- wrap the map in the Y direction
  if bg_y >= 256 then
    bg_y = bg_y - 256
  end
  local w_y = scanline + WY()
  local w_x = WX() + 7
  local window_visible = false
  if w_x <= 166 and w_y <= 143 then
    window_visible = true
  end

  for x = 0, 159 do
    if LCD_Control.BackgroundEnabled() then
      local bg_color = graphics.getColorFromTilemap(LCD_Control.BackgroundTilemap(), bg_x, bg_y)
      plot_pixel(graphics.game_screen, x, scanline, unpack(bg_color))
    end
    if LCD_Control.WindowEnabled() and window_visible then
      -- The window doesn't wrap, so make sure these coordinates are valid
      -- (ie, inside the window map) before attempting to plot a pixel
      if w_x >= 0 and w_x < 256 and w_y >= 0 and w_y < 256 then
        local window_color = graphics.getColorFromTilemap(LCD_Control.WindowTilemap(), w_x, w_y)
        plot_pixel(graphics.game_screen, x, scanline, unpack(window_color))
      end
    end
    bg_x = bg_x + 1
    if bg_x >= 256 then
      bg_x = bg_x - 256
    end
    w_x = w_x + 1
  end

  draw_sprites_into_scanline(scanline)
end

return graphics