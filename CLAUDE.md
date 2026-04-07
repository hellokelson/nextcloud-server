# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Nextcloud Server is a self-hosted cloud platform written in PHP and JavaScript (Vue.js). It provides file storage, sharing, calendar, contacts, and extensibility through an app ecosystem.

## Architecture

### PHP Backend Structure

- **`lib/public/` (OCP namespace)**: Public API for apps. Stable interface that apps should use.
- **`lib/private/` (OC namespace)**: Internal implementation. Apps should not depend on these classes.
- **`lib/unstable/` (NCU namespace)**: Unstable/experimental APIs not yet stabilized.
- **`core/`**: Core application logic and built-in functionality.
- **`apps/`**: Modular apps (files, dav, encryption, federation, etc.). Each app has:
  - `appinfo/info.xml` - App metadata
  - `lib/` - PHP classes (Controller, Service, Db, etc.)
  - `src/` - Vue.js frontend code (if applicable)
  - `tests/` - Unit and integration tests

### Frontend Structure

The frontend uses **two separate build systems** for Vue 2 (legacy) and Vue 3:
- **`build/frontend/`**: Vue 3 apps
- **`build/frontend-legacy/`**: Vue 2 apps
- **`build/demi.sh`**: Helper script that runs npm commands in both directories

## Development Commands

### Setup

```bash
# Install PHP dependencies
composer install

# Install npm dependencies (runs in both frontend directories)
npm ci

# Initialize git blame ignore list
git config blame.ignoreRevsFile .git-blame-ignore-revs
```

### Building

```bash
# Build all (clean, setup, build production JS)
make

# Build JavaScript for development
npm run dev
# or
make build-js

# Build JavaScript for production
npm run build
# or
make build-js-production

# Watch mode for development
npm run watch
# or
make watch-js

# Build SASS/CSS
npm run sass
npm run sass:watch
```

### Testing

**PHP Tests:**
```bash
# Run all PHP tests
composer test

# Run database-related tests only
composer test:db

# Run a specific test file
./lib/composer/bin/phpunit tests/lib/Files/FileTest.php

# Run tests with specific database (sqlite, mysql, pgsql, etc.)
./autotest.sh sqlite
./autotest.sh mysql tests/lib/Files/FileTest.php

# Run external storage tests
composer test:files_external
```

**JavaScript Tests:**
```bash
# Run frontend unit tests (Vitest)
npm run test

# Run tests with coverage
npm run test:coverage

# Run tests in watch mode
npm run test:watch

# Update test snapshots
npm run test:update-snapshots

# Run Cypress E2E tests
npm run cypress
npm run cypress:gui  # Open Cypress GUI
```

### Linting & Static Analysis

```bash
# PHP linting
composer lint

# PHP static analysis (Psalm)
composer psalm
composer psalm:strict        # Strict mode
composer psalm:ocp          # Check public API
composer psalm:security     # Security analysis

# PHP code style fix
composer cs:fix

# JavaScript/TypeScript linting
npm run lint
npm run lint:fix

# CSS linting
npm run stylelint
npm run stylelint:fix
```

### Running Locally

```bash
# Start development server (PHP built-in server)
composer serve
# Accessible at http://localhost:8080

# Or use the occ command-line tool
php occ [command]
# Example: php occ app:list
```

## Code Conventions

### Commits

Use **Conventional Commits** format:
```
feat(files_sharing): allow sharing with contacts
fix(dav): resolve calendar sync issue
chore(deps): update dependencies
```

All commits must be **signed-off** (DCO):
```bash
git commit -sm "Your commit message"
# or configure alias
git config --global alias.ci 'commit -s'
```

### Code Style

**PHP:**
- Tabs for indentation (size 4)
- Follow PSR-12 with Nextcloud extensions
- Use strict types: `declare(strict_types=1);`
- Run `composer cs:fix` before committing

**JavaScript/TypeScript:**
- Tabs for indentation (size 4)
- Use `@nextcloud/eslint-config`
- Run `npm run lint:fix` before committing

**Vue:**
- Use Composition API for new code
- Follow `@nextcloud/vue` component patterns

### Testing Requirements

- **All new code must include tests**
- PHP: PHPUnit tests in `tests/` directory
- JavaScript: Vitest tests co-located with source files
- E2E: Cypress tests in `cypress/` directory

## App Development

Apps follow this structure:
```
apps/myapp/
├── appinfo/
│   ├── info.xml           # App metadata
│   ├── routes.php         # Route definitions (optional)
│   └── Application.php    # Dependency injection container
├── lib/
│   ├── Controller/        # HTTP controllers
│   ├── Service/           # Business logic
│   ├── Db/               # Database entities and mappers
│   └── AppInfo/          # App bootstrap
├── src/                   # Vue.js frontend (if applicable)
├── templates/            # PHP templates (if not using Vue)
└── tests/                # Tests
    ├── Unit/
    └── Integration/
```

Key patterns:
- Use dependency injection via `Application.php`
- Controllers extend `OCP\AppFramework\Controller`
- Database entities extend `OCP\AppFramework\Db\Entity`
- Use `OCP\` (public API) classes, not `OC\` (internal)

## Key Files & Tools

- **`occ`**: Command-line tool (wraps `console.php`)
- **`autotest.sh`**: PHP test runner with database setup
- **`Makefile`**: Common build tasks
- **`composer.json`**: PHP dependencies and scripts
- **`package.json`**: Node dependencies and scripts
- **`psalm.xml`**: Static analysis configuration
- **`phpunit-autotest.xml`**: PHPUnit configuration

## Third-party Components

Third-party PHP libraries are in `3rdparty/` (git submodule). After cloning:
```bash
git submodule update --init
```

To update 3rdparty in a PR, comment: `/update-3rdparty`

## Notes

- Some apps (e.g., `firstrunwizard`, `activity`) are missing in `master` branch and must be cloned manually into `apps/` for development
- Never use `stable*` branches on production systems
- The frontend build uses a dual Vue 2/3 setup during transition period
- XDebug connects on port 9003 in DevContainer
