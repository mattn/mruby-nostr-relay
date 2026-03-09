MRuby::Build.new do |conf|
  # load specific toolchain settings
  conf.toolchain

  # gnu++20 needed for designated initializers in C code compiled as C++
  [conf.cc, conf.objc, conf.asm, conf.cxx].each do |compiler|
    compiler.cxx_compile_flag = '-x c++ -std=gnu++20'
  end
  conf.enable_cxx_abi
  conf.cc.flags << '-fpermissive'
  conf.cxx.flags << '-std=gnu++20'

  if ENV['OS'] != 'Windows_NT' then
    conf.cc.flags << %w|-fPIC| # needed for using bundled gems
  end

  conf.gem :github => 'mattn/mruby-json'
  conf.gem :github => 'mattn/mruby-onig-regexp'
  conf.gem :github => 'mattn/mruby-secp256k1', :branch => 'main'
  conf.gem :github => 'iij/mruby-digest'
  conf.gem :github => 'Asmod4n/mruby-phr'
  conf.gem :github => 'Asmod4n/mruby-poll'
  conf.gem :github => 'Asmod4n/mruby-wslay'
  conf.gem :github => 'mattn/mruby-postgresql', :branch => 'fix-string-param-format'
  conf.gem :github => 'iij/mruby-env'

  # include the GEM box
  conf.gembox 'default'
  conf.gembox 'stdlib-io'
  conf.gembox 'stdlib-ext'
end
