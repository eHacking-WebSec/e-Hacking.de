# e-hacking.de

This project provides an example configuration how we deploy our eHacking platfrom on [e-hacking.de](https://e-hacking.de)

# Deployment

- Configure your `.env` file. Setups hostnames, ports, etc.
- Configure your flags in `falgs/*.env`.
- Start the e-hacking deployment with: `docker compose --env-file flags.env --env-file .env up -d`