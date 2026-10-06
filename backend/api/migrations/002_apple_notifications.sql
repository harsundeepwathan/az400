-- App Store Server Notifications V2 (T1).
--
-- Notifications can arrive for transactions the server has never linked to a
-- user (the app never posted the purchase, or the account was deleted), so
-- subscriptions.user_id becomes nullable: such rows are stored unlinked and
-- claimed when the app later posts the transaction.
alter table subscriptions alter column user_id drop not null;

-- Apple does not guarantee delivery order. Transaction fields (product,
-- revocation) are applied only from a JWS signed at or after the one already
-- applied; renewal fields likewise from the renewal JWS.
alter table subscriptions
  add column last_signed_at timestamptz,
  add column auto_renew boolean,
  add column grace_period_expires_at timestamptz,
  add column renewal_signed_at timestamptz;

-- One row per notification Apple delivered and we verified. The primary key
-- makes redelivery idempotent. No user id: the transaction id is enough to
-- debug, and rows can be pruned freely (see README).
create table apple_notifications (
  notification_uuid uuid primary key,
  notification_type text not null check (length(notification_type) between 1 and 64),
  subtype text check (subtype is null or length(subtype) <= 64),
  environment text check (environment is null or environment in ('Production', 'Sandbox', 'Xcode', 'LocalTesting')),
  original_transaction_id text check (original_transaction_id is null or length(original_transaction_id) between 1 and 64),
  outcome text not null check (outcome in ('applied', 'unlinked', 'ignored')),
  signed_at timestamptz not null,
  received_at timestamptz not null default now()
);
create index apple_notifications_received_idx on apple_notifications (received_at);
