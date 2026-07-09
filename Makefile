# FOP spec — validation and resolution
VENV := .venv
PY   := $(VENV)/bin/python

.PHONY: setup validate resolve tf-fmt tf-validate tf-plan clean

setup:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip -q install pyyaml jsonschema

# Validate every catalog/role/user file against its schema + cross-references.
validate:
	$(PY) scripts/validate.py validate

# Show the resolved app set for a user: `make resolve USER=vireakyuth`
resolve:
	$(PY) scripts/validate.py resolve $(USER)

# Simulate an Abra heartbeat (dry-run, installs nothing):
#   make sim USER=sokha          resolve by handle
#   make sim SERIAL=FCQN7GT76Y   resolve by device serial (as MDM would)
sim:
	$(PY) scripts/abra_sim.py $(if $(SERIAL),--serial $(SERIAL),--user $(USER))

tf-fmt:
	cd terraform && terraform fmt -recursive

tf-validate:
	cd terraform && terraform init -backend=false -input=false && terraform validate

# Show the GitHub/AWS access the FOP spec resolves to (no cloud creds needed).
tf-plan:
	cd terraform && printf 'local.github_memberships\nlocal.aws_assignments\n' | terraform console

clean:
	rm -rf $(VENV) terraform/.terraform terraform/.terraform.lock.hcl
