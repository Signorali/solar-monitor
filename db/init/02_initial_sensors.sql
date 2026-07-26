-- Initial sensor entries (idempotent — INSERT...ON CONFLICT)
INSERT INTO sensors (code, type, display_name, address, port, config)
VALUES
  ('pzem_addr_11',  'pzem-017',       'Solar 1', 11, '/dev/solar_pzem', '{"shunt_amps": 50}'),
  ('pzem_addr_13',  'pzem-017',       'Batarya', 13, '/dev/solar_pzem', '{"shunt_amps": 200}'),
  ('jkbms_main',    'jk-bms',         'Ana Batarya BMS', NULL, '/dev/solar_bms', '{"cells": 16}'),
  ('inverter_main', 'voltronic-pi30', 'Ana Inverter', NULL, '/dev/solar_inverter', '{"baud": 2400}')
ON CONFLICT (code) DO NOTHING;
