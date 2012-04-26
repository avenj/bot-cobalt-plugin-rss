use Test::More tests => 3;

BEGIN {
  use_ok( 'Bot::Cobalt::Plugin::RSS' );
}
new_ok( 'Bot::Cobalt::Plugin::RSS' );
can_ok( 'Bot::Cobalt::Plugin::RSS', 'Cobalt_register', 'Cobalt_unregister' );
