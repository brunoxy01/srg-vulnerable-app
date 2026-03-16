-- MySQL initialisation script for the SRG Vulnerable App demo
-- Runs automatically when the mysql container starts for the first time

CREATE DATABASE IF NOT EXISTS vulndb;
USE vulndb;

CREATE TABLE IF NOT EXISTS users (
  id       INT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(50)  NOT NULL UNIQUE,
  password VARCHAR(100) NOT NULL,
  email    VARCHAR(100),
  role     VARCHAR(20) DEFAULT 'user'
);

INSERT INTO users (username, password, email, role) VALUES
  ('admin', 'admin123!',   'admin@example.com', 'admin'),
  ('john',  'password123', 'john@example.com',  'user'),
  ('jane',  'qwerty456',   'jane@example.com',  'user')
ON DUPLICATE KEY UPDATE username = username;
