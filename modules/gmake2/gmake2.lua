--
-- gmake2.lua
-- (c) 2016-2017 Jason Perkins, Blizzard Entertainment and the Premake project
--

	local p       = premake
	local project = p.project

	p.modules.gmake2 = {}
	p.modules.gmake2._VERSION = p._VERSION
	local gmake2 = p.modules.gmake2

--
-- Write out the default configuration rule for a workspace or project.
--
-- @param target
--    The workspace or project object for which a makefile is being generated.
--

	function gmake2.defaultconfig(target)
		-- find the right configuration iterator function for this object
		local eachconfig = iif(target.project, project.eachconfig, p.workspace.eachconfig)
		local defaultconfig = nil

		-- find the right default configuration platform, grab first configuration that matches
		if target.defaultplatform then
			for cfg in eachconfig(target) do
				if cfg.platform == target.defaultplatform then
					defaultconfig = cfg
					break
				end
			end
		end

		-- grab the first configuration and write the block
		if not defaultconfig then
			local iter = eachconfig(target)
			defaultconfig = iter()
		end

		if defaultconfig then
			_p('ifndef config')
			_x('  config=%s', defaultconfig.shortname)
			_p('endif')
			_p('')
		end
	end


---
-- Escape a string so it can be written to a makefile.
---

	function gmake2.esc(value)
		result = value:gsub("\\", "\\\\")
		result = result:gsub("\"", "\\\"")
		result = result:gsub(" ", "\\ ")
		result = result:gsub("%(", "\\(")
		result = result:gsub("%)", "\\)")

		-- leave $(...) shell replacement sequences alone
		result = result:gsub("$\\%((.-)\\%)", "$(%1)")
		return result
	end


--
-- Get the makefile file name for a workspace or a project. If this object is the
-- only one writing to a location then I can use "Makefile". If more than one object
-- writes to the same location I use name + ".make" to keep it unique.
--

	function gmake2.getmakefilename(this, searchprjs)
		local count = 0
		for wks in p.global.eachWorkspace() do
			if wks.location == this.location then
				count = count + 1
			end

			if searchprjs then
				for _, prj in ipairs(wks.projects) do
					if prj.location == this.location then
						count = count + 1
					end
				end
			end
		end

		if count == 1 then
			return "Makefile"
		else
			return ".make"
		end
	end


--
-- Output a makefile header.
--
-- @param target
--    The workspace or project object for which the makefile is being generated.
--

	function gmake2.header(target)
		local kind = iif(target.project, "project", "workspace")

		_p('# %s %s makefile autogenerated by Premake', p.action.current().shortname, kind)
		_p('')

		gmake2.defaultconfig(target)

		_p('ifndef verbose')
		_p('  SILENT = @')
		_p('endif')
		_p('')
	end


--
-- Rules for file ops based on the shell type. Can't use defines and $@ because
-- it screws up the escaping of spaces and parethesis (anyone know a fix?)
--

	function gmake2.mkdir(dirname)
		_p('ifeq (posix,$(SHELLTYPE))')
		_p('\t$(SILENT) mkdir -p %s', dirname)
		_p('else')
		_p('\t$(SILENT) mkdir $(subst /,\\\\,%s)', dirname)
		_p('endif')
	end

	function gmake2.mkdirRules(dirname)
		_p('%s:', dirname)
		_p('\t@echo Creating %s', dirname)
		gmake2.mkdir(dirname)
		_p('')
	end

--
-- Format a list of values to be safely written as part of a variable assignment.
--

	function gmake2.list(value, quoted)
		quoted = false
		if #value > 0 then
			if quoted then
				local result = ""
				for _, v in ipairs (value) do
					if #result then
						result = result .. " "
					end
					result = result .. p.quoted(v)
				end
				return result
			else
				return " " .. table.concat(value, " ")
			end
		else
			return ""
		end
	end


--
-- Convert an arbitrary string (project name) to a make variable name.
--

	function gmake2.tovar(value)
		value = value:gsub("[ -]", "_")
		value = value:gsub("[()]", "")
		return value
	end



	function gmake2.path(cfg, value)
		cfg = cfg.project or cfg
		local dirs = path.translate(project.getrelative(cfg, value))

		if type(dirs) == 'table' then
			dirs = table.filterempty(dirs)
		end

		return dirs
	end


	function gmake2.getToolSet(cfg)
		local default = iif(cfg.system == p.MACOSX, "clang", "gcc")
		local toolset = p.tools[_OPTIONS.cc or cfg.toolset or default]
		if not toolset then
			error("Invalid toolset '" .. cfg.toolset .. "'")
		end
		return toolset
	end


	function gmake2.outputSection(prj, callback)
		local root = {}

		for cfg in project.eachconfig(prj) do
			-- identify the toolset used by this configurations (would be nicer if
			-- this were computed and stored with the configuration up front)

			local toolset = gmake2.getToolSet(cfg)

			local settings = {}
			local funcs = callback(cfg)
			for i = 1, #funcs do
				local c = p.capture(function ()
					funcs[i](cfg, toolset)
				end)
				if #c > 0 then
					table.insert(settings, c)
				end
			end

			if not root.settings then
				root.settings = table.arraycopy(settings)
			else
				root.settings = table.intersect(root.settings, settings)
			end

			root[cfg] = settings
		end

		if #root.settings > 0 then
			for _, v in ipairs(root.settings) do
				p.outln(v)
			end
			p.outln('')
		end

		local first = true
		for cfg in project.eachconfig(prj) do
			local settings = table.difference(root[cfg], root.settings)
			if #settings > 0 then
				if first then
					_x('ifeq ($(config),%s)', cfg.shortname)
					first = false
				else
					_x('else ifeq ($(config),%s)', cfg.shortname)
				end

				for k, v in ipairs(settings) do
					p.outln(v)
				end

				_p('')
			end
		end

		if not first then
			p.outln('else')
			p.outln('  $(error "invalid configuration $(config)")')
			p.outln('endif')
			p.outln('')
		end
	end


---------------------------------------------------------------------------
--
-- Handlers for the individual makefile elements that can be shared
-- between the different language projects.
--
---------------------------------------------------------------------------

	function gmake2.phonyRules(prj)
		_p('.PHONY: clean prebuild prelink')
		_p('')
	end


	function gmake2.shellType()
		_p('SHELLTYPE := msdos')
		_p('ifeq (,$(ComSpec)$(COMSPEC))')
		_p('  SHELLTYPE := posix')
		_p('endif')
		_p('ifeq (/bin,$(findstring /bin,$(SHELL)))')
		_p('  SHELLTYPE := posix')
		_p('endif')
		_p('')
	end


	function gmake2.target(cfg, toolset)
		p.outln('TARGETDIR = ' .. project.getrelative(cfg.project, cfg.buildtarget.directory))
		p.outln('TARGET = $(TARGETDIR)/' .. cfg.buildtarget.name)
	end


	function gmake2.objdir(cfg, toolset)
		p.outln('OBJDIR = ' .. project.getrelative(cfg.project, cfg.objdir))
	end


	function gmake2.settings(cfg, toolset)
		if #cfg.makesettings > 0 then
			for _, value in ipairs(cfg.makesettings) do
				p.outln(value)
			end
		end

		local value = toolset.getmakesettings(cfg)
		if value then
			p.outln(value)
		end
	end


	function gmake2.buildCmds(cfg, event)
		_p('define %sCMDS', event:upper())
		local steps = cfg[event .. "commands"]
		local msg = cfg[event .. "message"]
		if #steps > 0 then
			steps = os.translateCommandsAndPaths(steps, cfg.project.basedir, cfg.project.location)
			msg = msg or string.format("Running %s commands", event)
			_p('\t@echo %s', msg)
			_p('\t%s', table.implode(steps, "", "", "\n\t"))
		end
		_p('endef')
	end


	function gmake2.preBuildCmds(cfg, toolset)
		gmake2.buildCmds(cfg, "prebuild")
	end


	function gmake2.preLinkCmds(cfg, toolset)
		gmake2.buildCmds(cfg, "prelink")
	end


	function gmake2.postBuildCmds(cfg, toolset)
		gmake2.buildCmds(cfg, "postbuild")
	end


	function gmake2.targetDirRules(cfg, toolset)
		gmake2.mkdirRules("$(TARGETDIR)")
	end


	function gmake2.objDirRules(cfg, toolset)
		gmake2.mkdirRules("$(OBJDIR)")
	end


	function gmake2.preBuildRules(cfg, toolset)
		_p('prebuild:')
		_p('\t$(PREBUILDCMDS)')
		_p('')
	end


	function gmake2.preLinkRules(cfg, toolset)
		_p('prelink:')
		_p('\t$(PRELINKCMDS)')
		_p('')
	end



	include("gmake2_cpp.lua")
	include("gmake2_csharp.lua")
	include("gmake2_makefile.lua")
	include("gmake2_utility.lua")
	include("gmake2_workspace.lua")

	return gmake2
