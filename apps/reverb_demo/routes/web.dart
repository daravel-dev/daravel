import 'package:daravel/daravel.dart';
import 'package:reverb_demo/demo.dart';

/// Web routes: a page pointing at the dashboard, and two buttons' worth of
/// broadcasts.
void webRoutes(Router router) {
  router
    ..get(
      '/',
      (Request request) => Response.html(
        '<!doctype html><title>Reverb demo</title>'
        '<p>Open <a href="/reverb">/reverb</a>. Broadcast with '
        '<code>POST /demo/announce</code> (the public <code>news</code> '
        'channel) or <code>POST /demo/ship/7</code> (private and encrypted '
        'order channels).</p>',
      ),
    )
    ..post('/demo/announce', (Request request) async {
      await Broadcast.send(
        'announcement',
        ['news'],
        {'text': 'Hello from the HTTP application'},
      );
      return Response.json({'sent': 'news'});
    })
    ..post('/demo/ship/{id}', (Request request) async {
      final id = request.param<int>('id');
      await Broadcast.event(OrderShipped(id));
      return Response.json({'shipped': id});
    });
}
