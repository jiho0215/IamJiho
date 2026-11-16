## Stage A
### P-core-1 · Add login rate limit
area: acme-api src/auth/**
depends:
Limit failed logins to 5 per minute.
### P-core-2 · Close user enumeration
ticket: acme/core#41
area: acme-api src/users/**
Return the same error for unknown and wrong-password.
### D-3 · Owner ruling on lockout
Lockout lasts 15 minutes.
