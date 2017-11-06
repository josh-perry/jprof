lf = love.filesystem
lg = love.graphics

msgpack = require "MessagePack"
inspect = require "inspect"

winW, winH = lg.getDimensions()

function love.load()
    frames = {}
    local fileData, msg = lf.read("bench.txt")
    assert(fileData, msg)
    data = msgpack.unpack(fileData)
    local nodeStack = {}
    for _, event in ipairs(data) do
        local top = nodeStack[#nodeStack]
        local name, time, memory = unpack(event)
        if name ~= "pop" then
            local node = {
                name = name,
                startTime = time,
                memoryStart = memory,
                children = {},
            }

            if name == "frame" then
                assert(#nodeStack == 0)
                node.index = #frames + 1
                table.insert(frames, node)
            else
                table.insert(top.children, node)
            end

            table.insert(nodeStack, node)
        else
            top.endTime = time + 1e-8
            top.deltaTime = top.endTime - top.startTime
            top.memoryEnd = memory
            top.memoryDelta = top.memoryEnd - top.memoryStart
            table.remove(nodeStack)
        end
    end

    frameDurMin, frameDurMax = math.huge, -math.huge
    memUsageMin, memUsageMax = math.huge, -math.huge
    memDeltaMin, memDeltaMax = math.huge, -math.huge
    for _, frame in ipairs(frames) do
        frameDurMin = math.min(frameDurMin, frame.deltaTime)
        frameDurMax = math.max(frameDurMax, frame.deltaTime)
        memUsageMin = math.min(memUsageMin, frame.memoryEnd)
        memUsageMax = math.max(memUsageMax, frame.memoryEnd)
        memDeltaMin = math.min(memDeltaMin, frame.memoryDelta)
        memDeltaMax = math.max(memDeltaMax, frame.memoryDelta)
    end

    currentFrame = frames[1]
    flameGraphType = "time"

    modeFont = lg.newFont(25)
    nodeFont = lg.newFont(18)
    graphFont = lg.newFont(12)
    lg.setLineJoin("none") -- lines freak out otherwise
    lg.setLineStyle("rough") -- lines are patchy otherwise
    love.keyboard.setKeyRepeat(true)

    -- setup graphs
    graphYRange = 200
    graphY = winH - 50 - graphYRange
    memGraph = {}
    timeGraph = {}
    deltaMemGraph = {}
    local subsamples = 1
    for i, frame in ipairs(frames) do
        local x = winW / (#frames - 1) * (i - 1)
        memGraph[#memGraph+1] = x
        memGraph[#memGraph+1] = graphY + rescale(0, memUsageMax, frame.memoryEnd, graphYRange, 0)

        deltaMemGraph[#deltaMemGraph+1] = x
        deltaMemGraph[#deltaMemGraph+1] = graphY + rescale(memDeltaMin, memDeltaMax, frame.memoryDelta, graphYRange, 0)

        local timeIndex = math.floor(i/subsamples)*2 + 1
        timeGraph[timeIndex+0] = (timeGraph[timeIndex+0] or 0) + x/subsamples
        local y = graphY + rescale(0, frameDurMax, frame.deltaTime, graphYRange, 0)
        -- subsample with min (instead of average), so we don't lose the spikes
        timeGraph[timeIndex+1] = math.min(timeGraph[timeIndex+1] or winH, y)
    end
end

function rescale(fromMin, fromMax, from, toMin, toMax)
    return (from - fromMin) / (fromMax - fromMin) * (toMax - toMin) + toMin
end

flameGraphFuncs = {}
function flameGraphFuncs.time(node, child)
    local x
    -- this will be false for averge frames for which we use center=true anyways
    if child.startTime and node.startTime and node.endTime then
        assert(child.startTime >= node.startTime and child.endTime <= node.endTime)
        x = (child.startTime - node.startTime) / (node.endTime - node.startTime)
    else
        x = 0
    end
    return x, child.deltaTime / node.deltaTime
end

function flameGraphFuncs.memory(node, child)
    -- if not same sign
    if node.memoryDelta * child.memoryDelta < 0 then
        return 0, 0
    else
        return 0, math.abs(child.memoryDelta) / math.abs(node.memoryDelta)
    end
end

function renderSubGraph(node, x, y, width, graphFunc, center)
    --print(node.name, x, y, width)

    local spacing = 2
    local font = lg.getFont()
    local height = math.floor(font:getHeight()*1.5)

    local hovered = nil
    local mx, my = love.mouse.getPosition()
    if mx > x and mx < x + width and my > y - height and my < y then
        hovered = node
        lg.setColor(255, 0, 0, 255)
        lg.rectangle("fill", x, y - height, width, height)
    end

    lg.setColor(200, 200, 200, 255)
    lg.rectangle("fill", x + spacing, y - height + spacing, width - spacing*2, height - spacing*2)


    lg.setScissor(x + spacing, y - height + spacing, width - spacing*2, height - spacing*2)
    lg.setColor(0, 0, 0, 255)
    local tx = x + spacing + spacing
    local ty = y - height/2 - font:getHeight()/2
    lg.print(node.name, tx, ty)
    lg.setColor(120, 120, 120, 255)
    lg.print(("%f ms, mem delta: %d Bytes"):format(node.deltaTime*1000, node.memoryDelta*1024),
        tx + font:getWidth(node.name) + 10, ty)
    lg.setScissor()

    local widthThresh = 5

    local totalChildrenWidth = 0
    if center then
        for i, child in ipairs(node.children) do
            local childX, childWidth = graphFunc(node, child)
            childWidth = math.floor(childWidth * width + 0.5)
            if childWidth >= widthThresh then
                totalChildrenWidth = totalChildrenWidth + childWidth
            end
        end
    end

    local nextChildX = math.floor((width - totalChildrenWidth) / 2 + x + 0.5)
    for i, child in ipairs(node.children) do
        local childX, childWidth = graphFunc(node, child)

        childX = math.floor(childX * width + x + 0.5)
        childWidth = math.floor(childWidth * width + 0.5)

        if center then
            childX = nextChildX
            nextChildX = nextChildX + childWidth
        end

        if childWidth >= widthThresh then
            local childHover = renderSubGraph(child, childX, y - height, childWidth, graphFunc, center)
            hovered = hovered or childHover
        end
    end

    return hovered
end

function getFramePos(i)
    return winW / (#frames - 1) * (i - 1)
end

function love.draw()
    -- render frame overview at the bottom
    local spacing = 1
    local width = (winW - spacing) / #frames - spacing
    local height = 30

    for i, frame in ipairs(frames) do
        local c = rescale(frameDurMin, frameDurMax, frame.deltaTime, 0, 255)
        assert(c >= 0 and c <= 255)
        lg.setColor(c, c, c, 255)
        local x, y = getFramePos(i) - width/2, winH - height - spacing
        lg.rectangle("fill", x, y, width, height - 5)
    end

    if currentFrame.index then
        lg.setColor(255, 0, 0, 255)
        local x = getFramePos(currentFrame.index)
        lg.line(x, graphY, x, winH)
    else
        lg.setColor(255, 0, 0, 50)
        local x, endX = getFramePos(currentFrame.fromIndex), getFramePos(currentFrame.toIndex)
        lg.rectangle("fill", x, graphY, endX - x, winH - graphY)
    end

    -- render graphs
    lg.setFont(graphFont)
    lg.setColor(80, 80, 80, 255)
    lg.line(0, graphY, winW, graphY)
    lg.line(0, graphY + graphYRange, winW, graphY + graphYRange)
    local totalDur = frames[#frames].endTime - frames[1].startTime
    local interval = math.floor(totalDur / 10)
    local lastSec = 0
    for i, frame in ipairs(frames) do
        local x = getFramePos(i)
        local sec = math.floor(frame.startTime - frames[1].startTime)
        if sec ~= lastSec and sec % interval == 0 then
            lg.print(tostring(sec), x, graphY)
            lg.line(x, graphY, x, graphY + graphYRange)
        end
        lastSec = sec
    end

    lg.setColor(255, 0, 255, 255)
    lg.print(("frame time (max: %f ms)"):format(frameDurMax*1000),
        5, graphY + lg.getFont():getHeight())
    lg.line(timeGraph)

    lg.setColor(0, 255, 0, 255)
    lg.print(("memory usage (max: %d KB)"):format(memUsageMax), 5, graphY)
    lg.line(memGraph)

    -- this graph is kind of confusing
    --lg.setColor(0, 100, 0, 255)
    --lg.line(deltaMemGraph)

    -- render flame graph for current frame
    lg.setColor(255, 255, 255, 255)
    lg.setFont(modeFont)
    lg.print("graph type: " .. flameGraphType, 5, 5)
    lg.setFont(nodeFont)
    -- do not order flame layers (just center) if either memory graph or average frame
    local hovered = renderSubGraph(currentFrame, 0, graphY - 40, winW,
        flameGraphFuncs[flameGraphType], flameGraphType == "memory" or not currentFrame.index)
    if hovered then
        lg.print(("%s - %f ms, mem delta: %d Bytes"):format(hovered.name,
            hovered.deltaTime*1000, hovered.memoryDelta*1024), 5, graphY - 35)
    end
end

function getChildByName(node, name)
    for _, child in ipairs(node.children) do
        if child.name == name then
            return child
        end
    end
    return nil
end

function addNode(intoNode, node)
    intoNode.deltaTime = intoNode.deltaTime + node.deltaTime
    intoNode.memoryDelta = intoNode.memoryDelta + node.memoryDelta

    for _, child in ipairs(node.children) do
        local intoChild = getChildByName(intoNode, child.name)
        if not intoChild then
            intoChild = {
                name = child.name,
                deltaTime = 0,
                memoryDelta = 0,
                children = {},
            }
            table.insert(intoNode.children, intoChild)
        end
        addNode(intoChild, child)
    end
end

-- just rescale times, because I care more about average times
-- and about total memory
function rescaleNode(node, factor)
    node.deltaTime = node.deltaTime * factor
    for _, child in ipairs(node.children) do
        rescaleNode(child, factor)
    end
end

function getFrameAverage(fromFrame, toFrame)
    local frame = {
        fromIndex = fromFrame.index,
        toIndex = toFrame.index,
        name = "frame",
        deltaTime = 0,
        memoryDelta = 0,
        children = {},
    }

    for i = fromFrame.index, toFrame.index do
        addNode(frame, frames[i])
    end

    rescaleNode(frame, 1/(frame.toIndex - frame.fromIndex + 1))

    return frame
end

function love.keypressed(key)
    local ctrl = love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")
    delta = ctrl and 100 or 1
    if key == "left" then
        if currentFrame.index then -- average frames don't have .index
            currentFrame = frames[math.max(1, currentFrame.index - delta)]
        end
    elseif key == "right" then
        if currentFrame.index then -- average frames don't have .index
            currentFrame = frames[math.min(#frames, currentFrame.index + delta)]
        end
    end

    if key == "space" then
        flameGraphType = flameGraphType == "time" and "memory" or "time"
    end

    if key == "return" then
        print(inspect(currentFrame))
    end
end

function pickFrame(x)
    return frames[math.floor(x / winW * #frames) + 1]
end

function love.mousepressed(x, y, button)
    local shift = love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift")
    if button == 1 and y > graphY then
        local frame = pickFrame(x)
        if shift then
            if currentFrame.index then
                currentFrame = getFrameAverage(currentFrame, frame)
            else
                if frame.index > currentFrame.fromIndex then
                    currentFrame = getFrameAverage(frames[currentFrame.fromIndex], frame)
                else
                    currentFrame = getFrameAverage(frame, frames[currentFrame.toIndex])
                end
            end
        else
            currentFrame = frame
        end
    end
end