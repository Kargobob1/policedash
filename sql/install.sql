-- PoliceDash / PolDash - Messprotokolle (optional, nur mit oxmysql).
-- Die Resource legt die Tabelle beim Start auch selbst an; diese Datei ist fuer manuelle Installationen.

CREATE TABLE IF NOT EXISTS policedash_measurements (
  id           VARCHAR(20) PRIMARY KEY,
  mode         VARCHAR(10) NOT NULL,
  created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  officer_id   VARCHAR(64),
  officer_name VARCHAR(100),
  target_plate VARCHAR(12),
  target_model VARCHAR(50),
  street       VARCHAR(100),
  measured     DECIMAL(6,1),
  tolerance    DECIMAL(5,1),
  chargeable   DECIMAL(6,1),
  unit         VARCHAR(4),
  duration     DECIMAL(6,2),
  distance     DECIMAL(8,1),
  image_url    VARCHAR(255),
  video_url    VARCHAR(255),
  data         LONGTEXT,
  INDEX idx_policedash_plate (target_plate)
);
