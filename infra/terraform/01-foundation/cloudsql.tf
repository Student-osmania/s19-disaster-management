# Cloud SQL for PostgreSQL - relational data (resources, reservations, dispatch assignments).
# There is NO free tier for Cloud SQL: db-f1-micro (shared core) is the cheapest tier.
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "google_sql_database_instance" "pg" {
  name                = "s19-pg"
  region              = var.region
  database_version    = "POSTGRES_15"
  deletion_protection = false

  settings {
    tier              = "db-f1-micro"
    edition           = "ENTERPRISE"
    availability_type = "ZONAL"
    disk_type         = "PD_HDD"
    disk_size         = 10
    disk_autoresize   = false
    activation_policy = var.cloudsql_running ? "ALWAYS" : "NEVER"

    ip_configuration {
      ipv4_enabled                                  = false # private IP only
      private_network                               = google_compute_network.vpc.id
      enable_private_path_for_google_cloud_services = true
    }
    backup_configuration { enabled = false } # coursework: no backups -> no backup storage charges
    insights_config { query_insights_enabled = false }
    location_preference { zone = var.zone }
    database_flags {
      name  = "max_connections"
      value = "50"
    }
  }
  depends_on = [google_service_networking_connection.psa]
}

resource "google_sql_database" "s19" {
  name     = "s19"
  instance = google_sql_database_instance.pg.name
}

resource "google_sql_user" "app" {
  name     = "s19app"
  instance = google_sql_database_instance.pg.name
  password = random_password.db.result
}
