use Test::More tests => 1;

BEGIN {
  use_ok( 'Cobalt::Plugin::RSS' );
}
new_ok( 'Cobalt::Plugin::RSS' );
can_ok( 'Cobalt::Plugin::RSS', 'Cobalt_register', 'Cobalt_unregister' );
