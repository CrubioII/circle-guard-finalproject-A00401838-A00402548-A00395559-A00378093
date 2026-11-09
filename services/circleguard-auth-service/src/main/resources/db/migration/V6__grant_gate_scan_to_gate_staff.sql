-- US-33 (SCRUM-112): el rol GATE_STAFF se creo en V1 sin ningun permiso, por lo
-- que el personal de porteria (staff_guard) no podia escanear QR en el ingreso.
-- Se otorga gate:scan de forma idempotente (nunca se editan migraciones ya aplicadas).
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.name = 'GATE_STAFF' AND p.name = 'gate:scan'
ON CONFLICT (role_id, permission_id) DO NOTHING;
