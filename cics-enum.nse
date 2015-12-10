local stdnse    = require "stdnse"
local shortport = require "shortport"
local tn3270    = require "tn3270"
local brute     = require "brute"
local creds     = require "creds"
local unpwdb    = require "unpwdb"

description = [[
CICS transaction ID enumerator for IBM mainframes.
This script is based on mainframe_brute by Dominic White
(https://github.com/sensepost/mainframe_brute). However, this script
doesn't rely on any third party libraries or tools and instead uses
the NSE TN3270 library which emulates a TN3270 screen in lua.

CICS only allows for 4 byte transaction IDs, that is the only specific rule
found for CICS transaction IDs.
]]

-- @args idlist Path to list of transaction IDs.
--  Defaults to the list of CICS transactions from IBM.
-- @args cics-enum.commands Commands in a semi-colon seperated list needed
--  to access CICS. Defaults to <code>CICS</code>.
-- @args cics-enum.path Folder used to store valid transaction id 'screenshots'
--  Defaults to <code>None</code> and doesn't store anything.
--
-- @usage
-- nmap --script=cics-enum -p 23 <targets>
--
-- nmap --script=cics-enum --script-args=idlist=default_cics.txt,
-- cics-enum.command="exit;logon applid(cics42)",
-- cics-enum.path="/home/dade/screenshots/",cics-enum.noSSL=true -p 23 <targets>
--
-- @output
-- PORT   STATE SERVICE
-- 23/tcp open  tn3270
-- | cics-enum:
-- |   Accounts:
-- |     CBAM: Valid - CICS Transaction ID
-- |     CETR: Valid - CICS Transaction ID
-- |     CEST: Valid - CICS Transaction ID
-- |     CMSG: Valid - CICS Transaction ID
-- |     CEDA: Valid - CICS Transaction ID
-- |     CEDF: Potentially Valid - CICS Transaction ID
-- |     DSNC: Valid - CICS Transaction ID
-- |_  Statistics: Performed 31 guesses in 114 seconds, average tps: 0
--
-- @changelog
-- 2015-07-04 - v0.1 - created by Soldier of Fortran
-- 2015-11-14 - v0.2 - rewrote iterator
--
-- @author Philip Young
-- @copyright Same as Nmap--See http://nmap.org/book/man-legal.html
--

author = "Philip Young aka Soldier of Fortran"
license = "Same as Nmap--See http://nmap.org/book/man-legal.html"
categories = {"intrusive", "brute"}
portrule = shortport.port_or_service({23,992}, "tn3270")

--- Saves the Screen generated by the CICS command to disk
--
-- @param filename string containing the name and full path to the file
-- @param data contains the data
-- @return status true on success, false on failure
-- @return err string containing error message if status is false
local function save_screens( filename, data )
	local f = io.open( filename, "w")
	if not f then return false, ("Failed to open file (%s)"):format(filename) end
	if not(f:write(data)) then return false, ("Failed to write file (%s)"):format(filename) end
	f:close()
	return true
end

Driver = {
  new = function(self, host, port, options)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.host = host
    o.port = port
    o.options = options
    o.tn3270 = Telnet:new()
    return o
  end,
  connect = function( self )
    local status, err = self.tn3270:initiate(self.host,self.port)
    self.tn3270:get_screen_debug()
    if not status then
      stdnse.debug("Could not initiate TN3270: %s", err )
      return false
    end
    return true
  end,
  disconnect = function( self )
    self.tn3270:disconnect()
    self.tn3270 = nil
    return true
  end,
  login = function (self, user, pass) -- pass is actually the CICS transaction we want to try
    local commands = self.options['key1']
    local path = self.options['key2']
    local timeout = 300
    local max_blank = 1
    local loop = 1
    local err
    stdnse.debug(2,"Getting to CICS")
    local run = stdnse.strsplit(";%s*", commands)
    for i = 1, #run do
      stdnse.debug(1,"Issuing Command (#%s of %s): %s", i, #run ,run[i])
      self.tn3270:send_cursor(run[i])
      self.tn3270:get_all_data()
      self.tn3270:get_screen_debug()
    end
    while self.tn3270:isClear() and max_blank < 7 do
      stdnse.debug(2, "Screen is not clear for %s. Reading all data with a timeout of %s. Count %s",pass, timeout, max_blank)
      self.tn3270:get_all_data(timeout)
      timeout = timeout + 100
      max_blank = max_blank + 1
    end

    while not self.tn3270:isClear() and loop < 10 do
    -- by this point we're at *some* CICS transaction
    -- so we send F3 to exit it
      stdnse.debug(2,"Sending: F3")
      self.tn3270:send_pf(3) -- send F3
      self.tn3270:get_all_data()
      self.tn3270:get_screen_debug()
      -- now we want to clear the screen
      self.tn3270:send_clear()
      self.tn3270:get_all_data()
      stdnse.debug(2,"Current CLEARed Screen. Loop: %s", loop )
      self.tn3270:get_screen_debug()
      loop = loop + 1
    end

    if loop == 10 then
      -- something is wrong but we can still try transactions. Print error to debug.
      stdnse.debug('Error. Failed to get to a blank screen under CICS (sending F3 followed by CLEAR). Try lowering maxthreads to fix.')
    end
    stdnse.verbose("Trying Transaction ID: %s", pass)
    stdnse.debug(2,"Sending Transaction ID: %s", pass)
    self.tn3270:send_cursor(pass)
    self.tn3270:get_all_data()

    max_blank = 1
    while self.tn3270:isClear() and max_blank < 7 do
      stdnse.debug(2, "Screen is not clear for %s. Reading all data with a timeout of %s. Count %s",pass, timeout, max_blank)
      self.tn3270:get_all_data(timeout)
      timeout = timeout + 100
      max_blank = max_blank + 1
    end

    stdnse.debug(2,"Screen Recieved for Transaction ID: %s", pass)
    self.tn3270:get_screen_debug()
    if self.tn3270:find('not recognized') then -- known invalid command
      stdnse.debug("Invalid CICS Transaction ID: %s", string.upper(pass))
      return false,  brute.Error:new( "Incorrect CICS Transaction ID" )
    elseif self.tn3270:isClear() then
      stdnse.debug(2,"Empty Screen when we expect an error.")
      -- this can mean that the transaction ID was valid
      -- but it didn't send a screen update so you should check by hand.
      -- We're not dumping this screen to disk because it's blank.
      return true, creds.Account:new("CICS ID [blank screen]", string.upper(pass), creds.State.VALID)
    elseif self.tn3270:find('Unauthorized') or self.tn3270:find('DFHAC2002') then
    -- this is a VALID cics transaction but you must be authenticated to used it
    -- This will be the same screen for each so we dont bother saving it either
      stdnse.verbose("Valid CICS Transaction ID [requires auth]: %s", string.upper(pass))
      return true, creds.Account:new("CICS ID [requires auth]", string.upper(pass), creds.State.VALID)
    else
      stdnse.verbose("Valid CICS Transaction ID: %s", string.upper(pass))
      if path ~= nil then
        stdnse.verbose(2,"Writting screen to: %s", path..string.upper(pass)..".txt")
        status, err = save_screens(path..string.upper(pass)..".txt",self.tn3270:get_screen())
        if not status then
          stdnse.verbose(2,"Failed writting screen to: %s", path..string.upper(pass)..".txt")
        end
      end
      return true, creds.Account:new("CICS ID", string.upper(pass), creds.State.VALID)
    end
    return false, brute.Error:new("Something went wrong, we didn't get a proper response")
  end
}

--- Tests the target to see if we can even get to CICS
--
-- @param host host NSE object
-- @param port port NSE object
-- @param commands optional script-args of commands to use to get to CICS
-- @return status true on success, false on failure

local function cics_test( host, port, commands )
  stdnse.debug("Checking for CICS")
  local tn = Telnet:new()
  local status, err = tn:initiate(host,port)
  local cics = false -- initially we're not at CICS
  if not status then
    stdnse.debug("Could not initiate TN3270: %s", err )
    return cics
  end
  tn:get_screen_debug() -- prints TN3270 screen to debug
  stdnse.debug("Getting to CICS")
  local run = stdnse.strsplit(";%s*", commands)
  for i = 1, #run do
    stdnse.debug(1,"Issuing Command (#%s of %s): %s", i, #run ,run[i])
    tn:send_cursor(run[i])
    tn:get_all_data()
    tn:get_screen_debug()
  end
  tn:get_all_data()
  tn:get_screen_debug() -- for debug purposes
  -- we should technically be at CICS. So we send:
  --   * F3 to exit the CICS program
  --   * CLEAR (a tn3270 command) to clear the screen.
  --     (you need to clear before sending a transaction ID)
  --   * a known default CICS transaction ID with predictable outcome
  --     (CESF with 'Sign-off is complete.' as the result)
  -- to confirm that we were in CICS. If so we return true
  -- otherwise we return false
  count = 1
  while not tn:isClear() and count < 6 do
    -- some systems will just kick you off others are slow in responding
    -- this loop continues to try getting out of CICS 6 times. If it can't
    -- then we probably weren't in CICS to begin with.
    if tn:find("Signon") then
      stdnse.debug(2,"Found 'Signon' sending PF3")
      tn:send_pf(3)
      tn:get_all_data()
    end
    tn:get_all_data()
    stdnse.debug(2,"Clearing the Screen")
    tn:send_clear()
    tn:get_all_data()
    tn:get_screen_debug()
    count = count + 1
  end
  if count == 6 then
    return cics
  end
  stdnse.debug(2,"Sending CESF (CICS Default Sign-off)")
  tn:send_cursor('CESF')
  tn:get_all_data()
  if tn:isClear() then
    tn:get_all_data(1000)
  end
  tn:get_screen_debug()

  if tn:find('Sign-off is complete.') then
      tn:disconnect()
      cics = true
  end
  tn:disconnect()
  return cics
end

-- Filter iterator for unpwdb
-- CICS is limited to 4 characters.
local valid_cics = function(x)
  return (string.len(x) <= 4)
end

function iter(t)
  local i, val
  return function()
    i, val = next(t, i)
    return val
  end
end

action = function(host, port)
  local cics_id_file = stdnse.get_script_args("idlist")
  local path = stdnse.get_script_args(SCRIPT_NAME .. '.path') -- Folder for screenshots
  local commands = stdnse.get_script_args(SCRIPT_NAME .. '.commands') or 'cics'-- VTAM commands/macros to get to CICS
  local cics_ids = {"CADP", "CATA", "CATD", "CATR", "CBAM", "CCIN", "CCRL", "CDBC", "CDBD",
	                  "CDBF", "CDBI", "CDBM", "CDBN", "CDBO", "CDBQ", "CDBT", "CDFS", "CDST",
										"CDTS", "CEBR", "CEBT", "CECI", "CECS", "CEDA", "CEDB", "CEDC", "CEDF",
										"CEDX", "CEGN", "CEHP", "CEHS", "CEKL", "CEMN", "CEMT", "CEOT", "CEPD",
										"CEPF", "CEPH", "CEPM", "CEPQ", "CEPS", "CEPT", "CESC", "CESD", "CESF",
										"CESL", "CESN", "CEST", "CETR", "CEX2", "CFCL", "CFCR", "CFOR", "CFQR",
										"CFQS", "CFTL", "CFTS", "CGRP", "CHLP", "CIDP", "CIEP", "CIND", "CIS1",
										"CIS4", "CISB", "CISC", "CISD", "CISE", "CISM", "CISP", "CISQ", "CISR",
										"CISS", "CIST", "CISU", "CISX", "CITS", "CJLR", "CJSA", "CJSL", "CJSR",
										"CJTR", "CKAM", "CKBC", "CKBM", "CKBP", "CKBR", "CKCN", "CKDL", "CKDP",
										"CKQC", "CKRS", "CKRT", "CKSD", "CKSQ", "CKTI", "CLDM", "CLQ2", "CLR1",
										"CLR2", "CLS1", "CLS2", "CLS3", "CLS4", "CMAC", "CMPX", "CMSG", "CMTS",
										"COVR", "CPCT", "CPIA", "CPIH", "CPIL", "CPIQ", "CPIR", "CPIS", "CPLT",
										"CPMI", "CPSS", "CQPI", "CQPO", "CQRY", "CRLR", "CRMD", "CRMF", "CRPA",
										"CRPC", "CRPM", "CRSQ", "CRSR", "CRST", "CRSY", "CRTE", "CRTP", "CRTX",
										"CSAC", "CSCY", "CSFE", "CSFR", "CSFU", "CSGM", "CSHA", "CSHQ", "CSHR",
										"CSKP", "CSMI", "CSM1", "CSM2", "CSM3", "CSM5", "CSNC", "CSNE", "CSOL",
										"CSPG", "CSPK", "CSPP", "CSPQ", "CSPS", "CSQC", "CSRK", "CSRS", "CSSF",
										"CSSY", "CSTE", "CSTP", "CSXM", "CSZI", "CTIN", "CTSD", "CVMI", "CWBA",
										"CWBG", "CWTO", "CWWU", "CWXN", "CWXU", "CW2A", "CXCU", "CXRE", "CXRT",
										"DSNC"} -- Default CICS from https://www-01.ibm.com/support/knowledgecenter/SSGMCP_5.2.0/com.ibm.cics.ts.systemprogramming.doc/topics/dfha726.html

  cics_id_file = ( (cics_id_file and nmap.fetchfile(cics_id_file)) or cics_id_file )

		if cics_id_file then
		  for l in io.lines(cics_id_file) do
		    if not l:match("#!comment:") then
		      table.insert(cics_ids, l)
		    end
		  end
		end

  if cics_test(host, port, commands) then
    local options = { key1 = commands, key2 = path }
    stdnse.debug("Starting CICS Transaction ID Enumeration")
    if path ~= nil then stdnse.verbose(2,"Saving Screenshots to: %s", path) end
    local engine = brute.Engine:new(Driver, host, port, options)
    engine.options.script_name = SCRIPT_NAME
    engine:setPasswordIterator(unpwdb.filter_iterator(iter(cics_ids), valid_cics))
    engine.options.passonly = true
    engine.options:setTitle("CICS Transaction ID")
    local status, result = engine:start()
    return result
  else
    return "Could not get to CICS. Aborting."
  end
end
