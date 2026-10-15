-- __feature__: one row per __entity__, scoped to its tenant.
create table __feature__ (
    tenant_id text not null,
    id text not null,
    title text not null,
    body text not null default '',
    created_at timestamptz not null default now(),
    primary key (tenant_id, id)
);
