-- The slice of the GIANTS XML API the junction registry uses, backed by REAL files on disk, so the
-- harness reads and writes ADFlyoverEditor_junctions.xml with the editor's own reader and writer
-- (junctionRegistryReadFile / junctionRegistryWriteFile) - and a "restart" can be a second lua.exe
-- reading what the first one wrote. Loaded by harness.lua when REGDIR is set, and by
-- split_registry.lua. Keys follow the engine's form: a.b.c(i)#attr, indices from 0.
--
-- Written the way the engine writes this file, so a file the game wrote reads and writes back the
-- same: a byte-order mark, CRLF line ends, four spaces a level, an empty element closed as <x/>,
-- attributes in the order first set, and floats as %.6f.
local function newNode(name) return { name = name, attrs = {}, attrOrder = {}, kids = {} } end

local function child(node, name, idx, create)
    local n = -1
    for _, k in ipairs(node.kids) do
        if k.name == name then
            n = n + 1
            if n == idx then return k end
        end
    end
    if not create then return nil end
    local k
    while n < idx do k = newNode(name); node.kids[#node.kids + 1] = k; n = n + 1 end
    return k
end

local function walk(xml, key, create)
    local path, attr = key:match("^([^#]*)#?(.*)$")
    local node, first = nil, true
    for seg in path:gmatch("[^%.]+") do
        local name, idx = seg:match("^([^%(]+)%((%d+)%)$")
        name, idx = name or seg, tonumber(idx) or 0
        if first then
            if xml.root == nil or xml.root.name ~= name then return nil end
            node, first = xml.root, false
        else
            node = child(node, name, idx, create)
            if node == nil then return nil end
        end
    end
    return node, (attr ~= "" and attr or nil)
end

local function unescape(s)
    return (s:gsub("&quot;", '"'):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&apos;", "'"):gsub("&amp;", "&"))
end
local function escape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

function fileExists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

function createXMLFile(_, path, rootName) return { path = path, root = newNode(rootName) } end

function loadXMLFile(_, path)
    local f = io.open(path, "rb")
    if f == nil then return nil end
    local s = f:read("*a"); f:close()
    local xml, stack = { path = path }, {}
    -- "<?xml ...?>" and the byte-order mark before it do not match a tag name, so they are skipped.
    for close, name, attrs, selfClose in s:gmatch("<(/?)([%w_]+)([^>]-)(/?)>") do
        if close == "/" then
            table.remove(stack)
        else
            local node = newNode(name)
            for k, v in attrs:gmatch('([%w_]+)="([^"]*)"') do
                node.attrs[k] = unescape(v); node.attrOrder[#node.attrOrder + 1] = k
            end
            if #stack == 0 then
                xml.root = node
            else
                local parent = stack[#stack]
                parent.kids[#parent.kids + 1] = node
            end
            if selfClose ~= "/" then stack[#stack + 1] = node end
        end
    end
    return xml
end

local function set(xml, key, v)
    local node, attr = walk(xml, key, true)
    assert(node and attr, "bad key " .. key)
    if node.attrs[attr] == nil then node.attrOrder[#node.attrOrder + 1] = attr end
    node.attrs[attr] = v
end
function setXMLInt(xml, key, v) set(xml, key, string.format("%d", v)) end
function setXMLFloat(xml, key, v) set(xml, key, string.format("%.6f", v)) end
function setXMLString(xml, key, v) set(xml, key, tostring(v)) end

local function get(xml, key)
    local node, attr = walk(xml, key, false)
    if node == nil or attr == nil then return nil end
    return node.attrs[attr]
end
function getXMLInt(xml, key) local v = tonumber(get(xml, key)); return v and math.floor(v) or nil end
function getXMLFloat(xml, key) return tonumber(get(xml, key)) end
function getXMLString(xml, key) return get(xml, key) end
--- An element key: is the element there. An attribute key: is the attribute there.
function hasXMLProperty(xml, key)
    local node, attr = walk(xml, key, false)
    if node == nil then return false end
    if attr ~= nil then return node.attrs[attr] ~= nil end
    return true
end

function saveXMLFile(xml)
    local out = { "\239\187\191" .. '<?xml version="1.0" encoding="utf-8" standalone="no"?>' }
    local function emit(node, depth)
        local pad, a = string.rep("    ", depth), {}
        for _, k in ipairs(node.attrOrder) do a[#a + 1] = string.format(' %s="%s"', k, escape(node.attrs[k])) end
        if #node.kids == 0 then
            out[#out + 1] = string.format("%s<%s%s/>", pad, node.name, table.concat(a))
        else
            out[#out + 1] = string.format("%s<%s%s>", pad, node.name, table.concat(a))
            for _, k in ipairs(node.kids) do emit(k, depth + 1) end
            out[#out + 1] = string.format("%s</%s>", pad, node.name)
        end
    end
    emit(xml.root, 0)
    -- Binary, with CRLF written out: in text mode the line ends would depend on the system.
    local f = assert(io.open(xml.path, "wb"))
    f:write(table.concat(out, "\r\n") .. "\r\n"); f:close()
    XML_WRITES = (XML_WRITES or 0) + 1
    return true
end

function delete() end
