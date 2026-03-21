target("AlphaRerankCore")
  set_kind("shared")
  set_basename("alpha_rerank_core")
  add_files("./*.cpp")
  add_links("kernel32", "rime")
  add_ldflags("/DEBUG /OPT:REF /OPT:ICF /ERRORREPORT:QUEUE")

  before_build(function(target)
    local target_dir = path.join(target:targetdir(), target:name())
    if not os.exists(target_dir) then
      os.mkdir(target_dir)
    end
    target:set("targetdir", target_dir)
  end)

  after_build(function(target)
    local output_root = is_arch("x86") and "$(projectdir)/output/Win32/lua/wanxiang" or "$(projectdir)/output/lua/wanxiang"
    os.mkdir(output_root)
    os.cp(target:targetfile(), output_root)

    local pdb = path.join(target:targetdir(), "alpha_rerank_core.pdb")
    if os.exists(pdb) then
      os.cp(pdb, output_root)
    end
  end)
