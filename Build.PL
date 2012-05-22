#!/usr/bin/env perl
use strict; use warnings;
use Module::Build;
my $build = Module::Build->new(
  module_name => "Bot::Cobalt::Plugin::RSS",
  dist_abstract => "RSS feed monitor for Cobalt",
  dist_author => 'Jon Portnoy <avenj@cobaltirc.org>',
  
  license => 'perl',
  
  create_makefile_pl => 'small',
  
  create_readme => 1,
  
  requires => {
    'perl' => '5.10.1',
    'File::Spec' => 0,
    
    'Bot::Cobalt::Core' => 0,

    'XML::RSS::Feed' => 0,    
  },
  
);

$build->create_build_script;
