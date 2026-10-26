# Mail and notifications

`Mail` sends email over SMTP (or another transport) and `Notifications`
sends a notification on several channels at once: mail, the database, or
your own. Both read Laravel's settings, and stored notifications use
Laravel's `notifications` table, so a Laravel application on the same
database lists them too.

## Configuration

The keys are those of Laravel 12's `config/mail.php`:

```dotenv
MAIL_MAILER=smtp              # smtp, log (the default), array, or your own transport
MAIL_SCHEME=smtp              # smtp (STARTTLS when offered) or smtps (TLS, port 465)
MAIL_HOST=smtp.example.com
MAIL_PORT=587
MAIL_USERNAME=postmaster@example.com
MAIL_PASSWORD=secret
MAIL_FROM_ADDRESS=hello@example.com
MAIL_FROM_NAME="${APP_NAME}"
```

- `log` writes each message, with its full MIME, to the log instead of
  sending it. As in Laravel it is the default, so nothing is sent by
  accident.
- `array` keeps messages in memory. It is the default with
  `APP_ENV=testing`.
- `MAIL_ENCRYPTION` from Laravel 10 `.env` files is read too: `ssl` means
  smtps, and `tls` requires STARTTLS. `MAIL_EHLO_DOMAIN` sets the EHLO
  name (the host of `APP_URL` by default) and `MAIL_TIMEOUT` the timeout
  of each SMTP step (30s).

SMTP is built in (pure Dart): EHLO, STARTTLS, `AUTH PLAIN`/`LOGIN`, one
connection per message. For a provider's HTTP API, register a transport:

```dart
.withMailTransport('postmark', (config) => PostmarkTransport(apiKey))
```

A transport implements `MailTransport.send(MailMessage message, String mime)`.
The message has the recipients and parts, and `mime` is the rendered RFC
5322 text.

## Mailables

<!-- dartisan make:mail OrderShipped -->
```dart
final class OrderShipped extends Mailable {
  OrderShipped(this.order);
  final Order order;

  @override
  Envelope envelope() => Envelope(
    subject: 'Order ${order.id} shipped',
    replyTo: [MailAddress('support@example.com', 'Support')],
  );

  @override
  MailContent content() => MailContent(
    html: '<p>Your order <b>${escapeHtml(order.number)}</b> is on its way.</p>',
    text: 'Your order ${order.number} is on its way.',
  );

  @override
  List<MailAttachment> attachments() => [
    MailAttachment.file('storage/app/invoices/${order.id}.pdf', as: 'invoice.pdf'),
  ];
}
```

`dartisan make:mail OrderShipped` writes one in `lib/app/mail/`. Escape
values you put into HTML with `escapeHtml`. Give a text part as well as the
HTML when you can, because clients and spam filters prefer messages that
have both.

```dart
await Mail.to(user).send(OrderShipped(order));
await Mail.to('Ops <ops@example.com>').cc(['a@example.com']).bcc(auditor).send(report);
```

Recipients are addresses, `Name <address>` strings, models with an `email`
(and `name`) attribute, or lists of them. The sender is the envelope's
`from`, or `MAIL_FROM_ADDRESS` / `MAIL_FROM_NAME`.

Messages are standard MIME: text and HTML as `multipart/alternative`,
quoted-printable bodies, base64 attachments, and RFC 2047 / 2231 encoding
for non-ASCII subjects, names and file names. Bcc recipients receive the
message without appearing in it. Subjects, names, addresses and headers
that contain a line break are refused with an `ArgumentError`, because
user input in a header would otherwise let someone add recipients.

### Markdown mail and the theme

`MailContent(markdown: ...)` is Laravel's markdown mailable: the markdown
becomes the HTML part inside the mail theme (header with `APP_NAME`, a
white card, the footer), and the text part unless `text:` is given.
Laravel's components are written as in Blade, or with `mailButton` and
`mailPanel`, which escape what they are given:

```dart
@override
MailContent content() => MailContent(
  markdown: '''
# Order ${escapeHtml(order.number)} shipped

It is on its way.

${mailButton('Track your order', order.trackingUrl, color: 'success')}

<x-mail::panel>
Delivery **tomorrow** between 9 and 12.
</x-mail::panel>

Thanks,<br>
${escapeHtml(appName)}
''',
);
```

The theme is Laravel 12's default (`default.css`), with its styles inlined
into every element, as Laravel does before sending, because many mail
clients ignore `<style>`. Buttons take `primary`, `success` or `error`.
Change the colors, the logo or the footer once for every mail:

```dart
Application.configure(basePath: '.')
    .withMailTheme((theme) => theme.copyWith(
      primary: '#4f46e5',
      logoUrl: 'https://example.com/logo.png',
    ))
```

Escape values you put into markdown with `escapeHtml`, as Blade's `{{ }}`
does; markdown syntax in them still works, as in Laravel.

## Notifications

<!-- dartisan make:notification InvoicePaid -->
```dart
final class InvoicePaid extends Notification {
  const InvoicePaid(this.invoice);
  final Invoice invoice;

  @override
  List<String> via(Object notifiable) => ['mail', 'database'];

  @override
  NotificationMail toMail(Object notifiable) => NotificationMail()
      .subject('Invoice paid')
      .line('We received your payment of ${invoice.total}.')
      .action('View invoice', 'https://example.com/invoices/${invoice.id}')
      .line('Thank you!');

  @override
  Map<String, Object?> toDatabase(Object notifiable) =>
      {'invoice_id': invoice.id, 'total': invoice.total};
}

await user.notify(InvoicePaid(invoice));                 // any model
await Notifications.send(admins, InvoicePaid(invoice));  // a list
await Notifications.route('mail', 'billing@example.com').notify(InvoicePaid(invoice));
```

`NotificationMail` is Laravel's notification `MailMessage`. It has a
greeting ("Hello!", or "Whoops!" after `.error()`), lines, an optional
button and a salutation ("Regards," and `APP_NAME`), rendered in the mail
theme from the same markdown as Laravel's `notifications::email` template,
with its "If you're having trouble clicking..." subcopy under the button,
and as text. The subject defaults to the class name as words
(`Invoice Paid`).
`toMail` can return a `Mailable` instead. The facade is `Notifications`
because `Notification` is the base class.

| Channel | Sends | Recipient |
| :-- | :-- | :-- |
| `mail` | `toMail` | the model's `email` and `name`, or a `Notifications.route('mail', ...)` address |
| `database` | `toDatabase` (or `toArray`) into `notifications` | a model |
| `broadcast` | `toBroadcast` (or `toArray`) to the [Broadcaster](responses.md#broadcasting-to-every-isolate) | the model's channel, or `Notifications.route('broadcast', 'channel')` |
| your own | `withNotificationChannel('sms', SmsChannel())` | `routeNotificationFor('sms', ...)` |

A model decides its own routes by implementing `RoutesNotifications`:

```dart
final class User extends Model implements RoutesNotifications {
  // ...
  @override
  Object? routeNotificationFor(String channel, Notification n) =>
      channel == 'sms' ? this['phone'] : null; // null: the default
}
```

### The notifications table

Add `CreateNotificationsTable()` to `bootstrap/migrations.dart`. It is
Laravel's `make:notifications-table` table (`id` UUID, `type`,
`notifiable_type`/`notifiable_id`, `data`, `read_at`, timestamps), and it
is created only when missing, so a database Laravel already migrated works
as it is. Rows are written as Laravel writes them:

- `type` is `App\Notifications\InvoicePaid` (override `databaseType`);
- `notifiable_type` is the model's `morphClass` (`App\Models\User`);
- `data` is JSON;
- each recipient gets its own UUID.

```dart
final unread = await user.notifications(unreadOnly: true); // newest first
await Notifications.markAsRead(user, [unread.first.id]);   // or all: markAsRead(user)
final count = await Notifications.unreadCount(user);
```

### Broadcast

The `broadcast` channel publishes Laravel's `BroadcastNotificationCreated`
event: the notifiable's channel is `App.Models.User.1` (its `morphClass`
with dots, then its key), and the message is

```json
{"event": "Illuminate\\Notifications\\Events\\BroadcastNotificationCreated",
 "data": {"invoice_id": 7, "total": 120000, "id": "<uuid>", "type": "App\\Notifications\\InvoicePaid"}}
```

with the data of `toBroadcast`, or `toArray` (as in Laravel, `toDatabase`
is not used), and the same `id` as the notification's database row.
`broadcastOn`, `broadcastAs` and `broadcastType` change the channels, the
event name and the type. A WebSocket route delivers it to the user's
browser or app:

```dart
r.ws('/ws/notifications', (socket, request) async {
  final user = await Auth.user<User>();
  await Broadcast.pipe(socket, ['App.Models.User.${user!.key}']);
}).middleware(const ['auth']);
```

This is Daravel's own WebSocket, not the Pusher protocol, so Laravel Echo
does not connect to it yet.

## Queueing

Sending over SMTP takes a round trip to another server. Queue the message
so the request does not wait for it:

```dart
await Mail.to(user).queue(OrderShipped(order));
await Mail.to(user).later(const Duration(minutes: 10), Reminder(order));

// Or make the class itself queued, as Laravel's ShouldQueue does:
final class OrderShipped extends Mailable with ShouldQueue {
  @override
  String? get queue => 'mail'; // optional; also connection and delay
  // ...
}
await Mail.to(user).send(OrderShipped(order)); // queued; returns null
```

Notifications use the same mixin:
`final class InvoicePaid extends Notification with ShouldQueue`.

- The `mail` channel queues the rendered mail.
- The `database` channel queues the row it will insert. Its id and
  timestamps are those of the moment it was sent.
- A custom channel can implement `QueueableNotificationChannel`:
  `prepare` runs when the notification is sent and returns JSON, and
  `deliver` gets that JSON back in the worker.
- Channels that do not implement it send right away.

Queued work runs on the framework's own jobs (`daravel:mail`,
`daravel:notification`), so nothing needs adding to `bootstrap/jobs.dart`.
`dartisan queue:work` sends them. A mail job is tried 3 times, with 10
seconds and then 1 minute between attempts.

Inside `DB.transaction` the job is pushed when the transaction commits and
dropped if it rolls back (`QUEUE_AFTER_COMMIT`, on by default), so a rolled
back order sends no "order confirmed" mail.

One difference from Laravel: the message is rendered when it is queued,
not in the worker. Laravel serializes the mailable and its models and
renders it later. Daravel has no reflection to rebuild arbitrary objects,
so the job carries the finished message, including its attachments. The
mail shows the data as it was when it was queued, which is usually what
you want, and the worker needs nothing but the mail settings.

## Testing

```dart
final mail = Mail.fake();
await registerUser(...);
mail.assertSent<WelcomeMail>((m) => m.hasTo('teo@example.com'));
mail.assertNotSent<OrderShipped>();
mail.assertQueued<OrderShipped>((m) => m.hasTo('teo@example.com'));
mail.assertNothingSent();      // sent only; assertNothingOutgoing() checks both

final notifications = Notifications.fake();
await order.ship();
notifications.assertSentTo<InvoicePaid>(user, (n, channels) => channels.contains('mail'));
notifications.assertSentOnDemand<InvoicePaid>();
notifications.assertSentTimes<InvoicePaid>(1);
```

`Mail.restore()` and `Notifications.restore()` undo the fakes. Without a
fake, tests still send nothing: `APP_ENV=testing` uses the `array`
transport, whose `messages` hold what was sent.
