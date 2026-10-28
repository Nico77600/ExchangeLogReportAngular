if (-not ('ServeFixtures' -as [type])) {
    $project = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Add-Type -LiteralPath (Join-Path $project 'collector\Tests\ServeFixtures.cs') -IgnoreWarnings -WarningAction SilentlyContinue -ReferencedAssemblies @(
        (Join-Path $project 'host\publish\Microsoft.Data.Sqlite.dll'),
        'System.Runtime', 'System.Data.Common', 'System.Reflection', 'System.Net.Sockets', 'System.Net.Primitives',
        'System.Text.Encoding.Extensions', 'System.IO', 'System.Collections', 'System.Linq.Expressions', 'System.ComponentModel.Primitives', 'netstandard'
    )
}

function Complete-StorageFixture($Store) {
    $tx = $Store.Begin()
    try { $Store.ReconcileMessageRollups($tx); $tx.Commit() } finally { $tx.Dispose() }
}

function Set-LegacyStorageFixture([Microsoft.Data.Sqlite.SqliteConnection]$Connection, [ValidateSet(6, 7, 8, 9, 10)][int]$Schema) {
    # Schema 10: the previous current shape (text rollup columns, no SMTP client structures, ix_smtp_latest).
    # Schema 9: the shape before it (wide exact-identity indexes, '#Fields' text in source_file.fields, no dictionary).
    # Schema 8: the shape before it (hash-only and DESC latest indexes, full-column UPDATE triggers).
    if ($Schema -in 8, 9, 10) { [ServeFixtures]::ConvertToLegacySyntheticFixture($Connection, $Schema); return }
    $c = $Connection.CreateCommand()
    try {
        $c.CommandText = @'
DROP TRIGGER IF EXISTS tr_smtp_transaction_client_insert;
DROP TRIGGER IF EXISTS tr_smtp_transaction_client_update;
DROP TRIGGER IF EXISTS tr_smtp_transaction_client_delete;
DROP INDEX IF EXISTS ix_smtp_client;
DROP INDEX IF EXISTS ix_smtp_unknown_peer;
ALTER TABLE smtp_transaction DROP COLUMN client_id;
DROP TABLE smtp_client_hour;
DROP TABLE smtp_client;
DROP TABLE smtp_client_value;
DROP TABLE smtp_client_pending;
DROP TABLE smtp_client_dirty;
DROP TABLE message_rollup_value;
UPDATE source_file SET fields=(SELECT d.text FROM source_fields d WHERE d.id=source_file.fields_id) WHERE fields_id IS NOT NULL;
ALTER TABLE source_file DROP COLUMN fields_id;
DROP TABLE source_fields;
DROP TRIGGER tr_message_event_rollup_insert;
DROP TRIGGER tr_message_event_rollup_update;
DROP TRIGGER tr_message_event_rollup_delete;
DROP TRIGGER tr_smtp_transaction_rollup_insert;
DROP TRIGGER tr_smtp_transaction_rollup_update;
DROP TRIGGER tr_smtp_transaction_rollup_delete;
DROP INDEX ix_msg_identity_time;
DROP INDEX ix_smtp_identity_time;
DROP INDEX IF EXISTS ix_smtp_latest;
DROP INDEX IF EXISTS ix_session_latest;
DROP TABLE message_rollup_dirty;
DROP TABLE message_rollup;
'@
        if ($Schema -eq 6) {
            $c.CommandText += @'
DROP TRIGGER tr_message_event_hash_insert;
DROP TRIGGER tr_message_event_hash_update;
DROP TRIGGER tr_smtp_transaction_hash_insert;
DROP TRIGGER tr_smtp_transaction_hash_update;
DROP INDEX IF EXISTS ix_msg_hash;
DROP INDEX IF EXISTS ix_smtp_hash;
ALTER TABLE message_event DROP COLUMN msg_hash;
ALTER TABLE smtp_transaction DROP COLUMN msg_hash;
CREATE INDEX ix_msg_id ON message_event(message_id);
CREATE INDEX ix_smtp_message ON smtp_transaction(message_id);
DELETE FROM metadata WHERE key='message_hash_algorithm';
'@
        }
        # A genuine schema-7 database still owns the hash-only indexes that schema 9 no longer creates.
        if ($Schema -eq 7) { $c.CommandText += 'CREATE INDEX ix_msg_hash ON message_event(msg_hash);CREATE INDEX ix_smtp_hash ON smtp_transaction(msg_hash);' }
        $c.CommandText += "UPDATE metadata SET value='$Schema' WHERE key='schema_version';"
        [void]$c.ExecuteNonQuery()
        # Remove the empty SQLite AUTOINCREMENT system table left by the schema-8 fixture.
        $c.CommandText = 'VACUUM;'
        [void]$c.ExecuteNonQuery()
    } finally { $c.Dispose() }
}
