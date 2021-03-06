module("bpf_kernel_ts",package.seeall)

package.path = package.path .. ";../deps/pflua/src/?.lua"

local savefile = require("pf.savefile")
local libpcap = require("pf.libpcap")

local ffi = require("ffi")

ffi.cdef[[
typedef void (*compile_filter_t)(char *f);
typedef int (*run_filter_on_packet_t)(uint32_t pkt_len, const uint8_t *pkt);
void *dlopen(const char *filename, int flag);
void *dlsym(void *handle, const char *symbol);
char *dlerror(void);
]]

local lib_handle

-- void compile_filter(char *f);
local kernel_compile_filter
-- int run_filter_on_packet(uint32_t pkt_len, const uint8_t *pkt);
local kernel_run_filter_on_packet

function load_dyn_funcs()
   local RTLD_LAZY = 0x0001
   lib_handle = ffi.C.dlopen("./ref/bpf-jit-kernel/libbpf_jit_kernel.so.1.0.0", RTLD_LAZY)
   if lib_handle == nil then
      print(ffi.C.dlerror())
      print("did you compile .so library? it should be at ./ref/bpf-jit-kernel/libbpf_jit_kernel.so.1.0.0 ...")
      print("try 'make -C ref/bpf-jit-kernel lib'")
      os.exit(-1)
   end
   kernel_compile_filter = ffi.cast("compile_filter_t", ffi.C.dlsym(lib_handle, "compile_filter"));
   kernel_run_filter_on_packet = ffi.cast("run_filter_on_packet_t", ffi.C.dlsym(lib_handle, "run_filter_on_packet"));
end

--[[
There is no directory listing function in Lua as
it's a compact language. Maybe we could use lfs but
it would create a dependency. In the meanwhile this
hackish scandir version should make the job.
--]]
function scandir(dirname)
   callit = os.tmpname()
   os.execute("ls -a1 "..dirname .. " >"..callit)
   f = io.open(callit,"r")
   rv = f:read("*all")
   f:close()
   os.remove(callit)
   tabby = {}
   local from  = 1
   local delim_from, delim_to = string.find(rv, "\n", from)
   while delim_from do
      table.insert(tabby, string.sub(rv, from , delim_from-1))
      from  = delim_to + 1
      delim_from, delim_to = string.find(rv, "\n", from)
   end
   return tabby
end

-- retrieve all .ts files under ts/test directory
-- TODO: ts/tests should be some kind of conf var
function get_all_plans()
   local filetab = scandir("ts/tests")
   local plantab = {}
   for _, v in ipairs(filetab) do
      if v:sub(-3) == ".ts" then
         plantab[#plantab+1] = "ts/tests/".. v
      end
   end
   return plantab
end

function prefix(p, s)
   return s:sub(1,#p) == p
end

function get_all_tests(p)
   local plan = {}
   local current = {}
   for line in io.lines(p) do
      -- id
      if prefix("id:", line) then
         current = tonumber(line:sub(#"id:"+1))
         plan[current] = {}
      -- description
      elseif prefix("description:", line) then
         plan[current]['description'] = line:sub(#"description:"+1)
      -- filter
      elseif prefix("filter:", line) then
         plan[current]['filter'] = line:sub(#"filter:"+1)
      -- pcap_file
      elseif prefix("pcap_file:", line) then
         plan[current]['pcap_file'] = line:sub(#"pcap_file:"+1)
      -- expected_result
      elseif prefix("expected_result:", line) then
         plan[current]['expected_result'] = tonumber(line:sub(#"expected_result:"+1))
      -- enabled
      elseif prefix("enabled:", line) then
         plan[current]['enabled'] = line:sub(#"enabled:"+1) == "true"
      end
   end
   return plan
end

local function uncompress_if_necessary(filename)
   local function file_exists(name)
      local f = io.open(name, "r")
      if f ~= nil then io.close(f) return true else return false end
   end
   if (not file_exists(filename)) then
      os.execute("unxz "..filename..".xz")
   end
end

function convert_filter_to_dec_numbers(str)
   local line = ""
   local cmd = "/usr/sbin/tcpdump -ddd -r ts/pcaps/igalia/empty.pcap '" .. str .. "' 2> /dev/null | tr '\n' ','"
   local io = assert(io.popen(cmd, 'r'))
   line = io:read()
   line = line:sub(1,#line-1)
   io.close()
   return ffi.new("char[?]", #line, line)
end

local function assert_count(filter, file, pkt_expected)
   local pkt_total = 0
   local pkt_match = 0
   local lapse = 0
   local pass = false
   local f = convert_filter_to_dec_numbers(filter)
   -- set default kernel filter
   kernel_compile_filter(f)
   uncompress_if_necessary(file)
   local records = savefile.records_mm(file)
   local start = os.clock()
   while true do
      local pkt, hdr = records()
      if not pkt then break end
      pkt_total = pkt_total + 1
      -- run default kernel filter
      if kernel_run_filter_on_packet(hdr.incl_len, pkt) ~= 0 then
	 pkt_match = pkt_match + 1
      end
   end
   lapse = os.clock() - start
   pass = pkt_match == pkt_expected
   return pkt_total, pkt_match, lapse, pass
end

function run_test_plan(p)

   local plan = get_all_tests(p)

   -- count enabled tests
   local count = 0
   for i, v in ipairs(plan) do
      if plan[i].enabled then
         count = count + 1
      end
   end

   -- show info about the plan
   print("enabled tests: " .. count .. " of " .. #plan)

   -- execute test case
   for i, t in pairs(plan) do
      print("\nTest case running ...")
      print("id: " .. i)
      print("description: " .. t['description'])
      print("filter: " .. t['filter'])
      print("pcap_file: " .. t['pcap_file'])
      print("expected_result: " .. t['expected_result'])
      io.write("enabled: ")
      if t['enabled'] then
         print("true")
      else
         print("false")
      end
      local pkt_match = 0
      local passed = false
      local elapsed_time = 0
      io.write("tc id " .. i)
      if t['enabled'] then
         pkt_total, pkt_match, elapsed_time, passed = assert_count(t['filter'], "ts/pcaps/"..t['pcap_file'], t['expected_result'])
         if passed then
            print(" PASS")
         else
            print(" FAIL (" .. pkt_match .. " != " .. t['expected_result'] .. ")")
         end
      else
         print(" SKIP")
      end
      print("tc id " .. i .. " ET " .. elapsed_time)
      print("tc id " .. i .. " TP " .. pkt_total)
      local pps = 0
      if elapsed_time ~= 0 then
	 pps = pkt_total / elapsed_time
      end
      print("tc id " .. i .. " PPS " .. pps)
   end
end

function run()
   load_dyn_funcs()
   local plantab = get_all_plans()
   for _, p in ipairs(plantab) do
      print("\n[*] Running test plan: ".. p .. "\n")
      local stat = run_test_plan(p)
   end
end
