--[[

  Copyright (C) 2016 Masatoshi Teruya

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
  THE SOFTWARE.

  lib/callee.lua
  lua-coop
  Created by Masatoshi Teruya on 16/12/26.

--]]
--- file scope variables
local Deque = require('deque');
local Coro = require('coop.coro');
local yield = coroutine.yield;
local setmetatable = setmetatable;
local pcall = pcall;
local unpack = unpack or table.unpack;
-- constants
-- local CO_OK = Coro.OK;
-- local CO_YIELD = Coro.YIELD;
-- local ERRRUN = Coro.ERRRUN;
-- local ERRSYNTAX = Coro.ERRSYNTAX;
-- local ERRMEM = Coro.ERRMEM;
-- local ERRERR = Coro.ERRERR;
-- event-status
local EV_ERR = -3;
local EV_HUP = -2;
local EV_NOOP = -1;
local EV_OK = 0;
local EV_TIMEOUT = 1;


--- class Callee
local Callee = {};


--- __call
function Callee:call( ... )
    local co = self.co;
    local ok, err;

    self.coop.callee = self;
    -- call with passed arguments
    ok, err = co( ... );
    self.coop.callee = false;

    if ok or self.term then
        self:dispose( ok or self.term, err );
    end
end


--- dispose
function Callee:dispose( ok, err )
    local event = self.coop.event;
    local root = self.root;

    -- revoke timer event
    if self.timer then
        event:revoke( self.timer );
        self.timer = nil;
    -- revoke signal events
    elseif self.sigset then
        for i = 1, #self.sigset do
            event:revoke( self.sigset:pop() );
        end
        self.sigset = nil;
    end

    -- revoke io events
    if #self.pool > 0 then
        local ioev = self.pool:pop();

        repeat
            local fd = ioev:ident();

            self.revs[fd] = nil;
            self.wevs[fd] = nil;
            event:revoke( ioev );
            ioev = self.pool:pop();
        until ioev == nil;
    end

    -- run exit function
    if self.exitfn then
        pcall( unpack( self.exitfn ) );
        self.exitfn = nil;
    end

    self.term = nil;
    self.root = nil;
    self.coop.pool:push( self );

    -- dispose child routines
    if #self.node > 0 then
        local runq = self.coop.runq;
        local child = self.node:pop();

        repeat
            runq:remove( child );
            child:dispose();
            child = self.node:pop();
        until child == nil;
    end

    if err then
        print( self.co:getres() );
    end

    -- call root node
    if root and root.wait then
        root.wait = nil;
        root:call( ok, self.co:getres() );
    end
end


--- exit
-- @param ...
function Callee:exit( ... )
    self.term = true;
    return yield( ... );
end


--- atexit
-- @param fn
-- @param ...
function Callee:atexit( fn, ... )
    self.exitfn = { fn, ... };
end


--- await
function Callee:await()
    if #self.node > 0 then
        self.wait = true;
        return yield();
    end
end


--- ioable
-- @param evs
-- @param fd
-- @param deadline
-- @return status
-- @return err
function Callee:ioable( evs, asa, fd, deadline )
    local event = self.coop.event;
    local item = evs[fd];
    local ioev, ev, hup, err;

    if item then
        local ok;

        ioev = item:data();
        ok, err = ioev:watch();
        if not ok then
            evs[fd] = nil;
            self.pool:remove( item );
            event:revoke( ioev );
            return EV_ERR, err;
        end
    -- register io(readable or writable) event
    else
        ioev, err = event[asa]( event, self, fd );
        if err then
            return EV_ERR, err;
        end
        item = self.pool:push( ioev );
        evs[fd] = item;
    end

    -- wait until event fired
    ev, hup = yield();

    -- got io event
    if ev == ioev then
        if hup then
            evs[fd] = nil;
            self.pool:remove( item );
            event:revoke( ioev );
            return EV_HUP;
        end

        ioev:unwatch();
        return EV_OK;
    end

    -- revoke io event
    -- unwatch io event
    evs[fd] = nil;
    self.pool:remove( item );
    event:revoke( ioev );

    error( 'invalid implements' );
end



--- readable
-- @param fd
-- @param deadline
-- @return status
-- @return err
function Callee:readable( fd, deadline )
    return self:ioable( self.revs, 'readable', fd, deadline );
end


--- writable
-- @param fd
-- @param deadline
-- @return status
-- @return err
function Callee:writable( fd, deadline )
    return self:ioable( self.wevs, 'writable', fd, deadline );
end


--- sleep
-- @param deadline
-- @param status
-- @param err
function Callee:sleep( deadline )
    local event = self.coop.event;
    local timer, ev, hup, err;

    -- register timer event
    timer, err = event:timer( self, deadline, true );
    if err then
        return EV_ERR, err;
    end

    self.timer = timer;
    ev, hup = yield();
    self.timer = nil;

    if ev == timer then
        return hup and EV_HUP or EV_OK;
    end

    -- revoke timer event
    event:revoke( timer );

    error( 'invalid implements' );
end


--- sigwait
-- @param deadline
-- @param ...
-- @param status
-- @param err
function Callee:sigwait( deadline, ... )
    local event = self.coop.event;
    local sigs = {...};
    local sigset = Deque.new();
    local sigmap = {};
    local ev, hup, signo, err;

    -- register signal events
    for i = 1, select( '#', ... ) do
        if sigs[i] then
            ev, err = event:signal( self, sigs[i], true );
            -- got error
            if err then
                -- revoke signal events
                for j = 1, #sigset do
                    event:revoke( sigset:pop() );
                end

                return EV_ERR, err;
            end

            -- maintain registered event
            sigset:push( ev );
            sigmap[ev] = true;
        end
    end

    -- no need to wait signal if empty
    if #sigset == 0 then
        return EV_NOOP;
    end

    -- wait registered signals
    self.sigset = sigset;
    ev, hup = yield();
    signo = ev:ident();
    self.sigset = nil;

    -- revoke signal events
    for i = 1, #sigset do
        event:revoke( sigset:pop() );
    end

    if sigmap[ev] then
        return signo;
    end

    error( 'invalid implements' );
end


--- init
-- @param coop
-- @param fn
-- @param ctx
-- @param ...
-- @return ok
-- @return err
function Callee:init( coop, fn, ctx, ... )
    if ctx then
        self.co:init( fn, ctx, coop, ... );
    else
        self.co:init( fn, coop, ... );
    end

    -- set relationship
    if self.coop.callee then
        self.root = self.coop.callee;
        self.root.node:push( self );
    end
end


--- new
-- @param coop
-- @param fn
-- @param ctx
-- @param ...
-- @return callee
-- @return err
local function new( coop, fn, ctx, ... )
    local co, callee, err;

    if ctx then
        co, err = Coro.new( fn, ctx, coop, ...  );
    else
        co, err = Coro.new( fn, coop, ...  );
    end

    if err then
        return nil, err;
    end

    callee = setmetatable({
        coop = coop,
        co = co,
        node = Deque.new(),
        pool = Deque.new(),
        revs = {},
        wevs = {}
    }, {
        __index = Callee
    });
    -- set relationship
    if coop.callee then
        callee.root = coop.callee;
        callee.root.node:push( callee );
    end

    return callee;
end


return {
    new = new,
    EV_ERR = EV_ERR,
    EV_HUP = EV_HUP,
    EV_NOOP = EV_NOOP,
    EV_OK = EV_OK,
    EV_TIMEOUT = EV_TIMEOUT
};

