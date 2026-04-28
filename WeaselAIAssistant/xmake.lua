target("WeaselAIAssistant")
  set_kind("binary")
  add_files("./WeaselAIAssistant.cpp")
  add_files("../WeaselServer/stdafx.cpp")
  add_files("../WeaselServer/AIAssistantDialog.cpp")
  add_files("../WeaselServer/AIAssistantService.cpp")
  add_files("../WeaselServer/AIAssistantStandalone.cpp")
  add_rules("add_rcfiles", "use_weaselconstants", "subwin")
  add_links("imm32", "kernel32", "rime", "Shcore")
  add_deps("RimeWithWeasel")
  add_includedirs("$(projectdir)/WeaselServer")
  add_files("$(projectdir)/PerMonitorHighDPIAware.manifest")
  add_ldflags("/DEBUG /OPT:REF /OPT:ICF /LARGEADDRESSAWARE /ERRORREPORT:QUEUE")
  before_build(function(target)
    local target_dir = path.join(target:targetdir(), target:name())
    if not os.exists(target_dir) then
      os.mkdir(target_dir)
    end
    target:set("targetdir", target_dir)
  end)
  after_build(function(target)
    if is_arch("x86") then
      os.cp(path.join(target:targetdir(), "WeaselAIAssistant.exe"), "$(projectdir)/output/Win32")
      os.cp(path.join(target:targetdir(), "WeaselAIAssistant.pdb"), "$(projectdir)/output/Win32")
    else
      os.cp(path.join(target:targetdir(), "WeaselAIAssistant.exe"), "$(projectdir)/output")
      os.cp(path.join(target:targetdir(), "WeaselAIAssistant.pdb"), "$(projectdir)/output")
    end
  end)
