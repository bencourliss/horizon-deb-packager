SHELL := /bin/bash
ARCH := $(shell tools/arch-tag)
# N.B. This number has to match the latest addition to the changelog in pkgsrc/deb/debian/changelog
subproject_names = anax anax-ui
subproject = $(addprefix bld/,$(subproject_names))

VERSION := $(shell cat VERSION)
aug_version = $(addprefix $(1)$(VERSION)~ppa~,$(2))
pkg_version = $(call aug_version,horizon-,$(1))
file_version = $(call aug_version,horizon_,$(1))

distribution_names = $(shell find pkgsrc/deb/meta/dist/* -maxdepth 0 -exec basename {} \;)
pkgstub = $(foreach dname,$(distribution_names),dist/$(1)$(call pkg_version,$(dname))_$(ARCH).deb)

meta = $(addprefix meta-,$(distribution_names))

bluehorizon_deb_packages = $(call pkgstub,blue)
horizon_deb_packages = $(call pkgstub,)
package = $(bluehorizon_deb_packages) $(horizon_deb_packages)

debian_shared = $(shell find ./pkgsrc/deb/shared/debian -type f | sed 's,^./pkgsrc/deb/shared/debian/,,g' | xargs)

DOCKER_TAG_PREFIX := horizon

all: meta

ifndef VERBOSE
.SILENT:
endif

clean: clean-src mostlyclean
	@echo "Use distclean target to revert all configuration, in addition to build artifacts, and clean up horizon_$(VERSION) branch"
	-rm bld/changelog.tmpl
	-rm -Rf horizon* bluehorizon*
	-rm -Rf bld

clean-src:
	for src in $(subproject); do \
		if [ -e $$src ]; then \
		  cd $$src && \
			git checkout . && \
			git reset --hard HEAD && \
			git clean -fdx; \
	  fi; \
	done

mostlyclean:
	-rm -Rf dist
	for src in $(subproject); do \
		if [ -e $$src ]; then \
			cd $$src && $(MAKE) clean; \
	  fi; \
	done

distclean: clean
	@echo "distclean"
	# TODO: add other files to reset that might have changed?
	-@git reset VERSION
	-@git checkout master && git branch -D horizon_$(VERSION)

bld/changelog.tmpl: pkgsrc/deb/meta/changelog.tmpl $(addsuffix /.git-gen-changelog,$(subproject))
	mkdir -p bld
	tools/render-debian-changelog "##DISTRIBUTIONS##" "##VERSION_RELEASE##" bld/changelog.tmpl pkgsrc/deb/meta/changelog.tmpl $(shell find bld -iname ".git-gen-changelog")

dist/$(call pkg_version,%)/debian:
	mkdir -p dist/$(call pkg_version,$*)/debian

# both creates directory and fills it: this is not the best use of make but it is trivial work that can stay flexible
dist/$(call pkg_version,%)/debian/fs-horizon: $(shell find pkgsrc/seed) | dist/$(call pkg_version,%)/debian
	dir=dist/$(call pkg_version,$*)/debian/fs-horizon && \
		mkdir -p $$dir && \
		./pkgsrc/mk-dir-trees $$dir && \
		cp -Ra ./pkgsrc/seed/horizon/fs/. $$dir && \
		echo "SNAP_COMMON=/var/horizon" > $$dir/etc/default/horizon && \
		envsubst < ./pkgsrc/seed/dynamic/horizon.tmpl >> $$dir/etc/default/horizon && \
		./pkgsrc/render-json-config ./pkgsrc/seed/dynamic/anax.json.tmpl $$dir/etc/horizon/anax.json.example && \
		cp pkgsrc/mk-dir-trees $$dir/usr/horizon/sbin/

dist/$(call pkg_version,%)/debian/fs-bluehorizon: dist/$(call pkg_version,%)/debian/fs-horizon $(shell find pkgsrc/seed) | dist/$(call pkg_version,%)/debian
	dir=dist/$(call pkg_version,$*)/debian/fs-bluehorizon && \
		mkdir -p $$dir && \
		cp -Ra ./pkgsrc/seed/bluehorizon/fs/. $$dir && \
		cp dist/$(call pkg_version,$*)/debian/fs-horizon/etc/horizon/anax.json.example $$dir/etc/horizon/anax.json

# meta for every distribution, the target of horizon_$(VERSION)-meta/$(distribution_names)
dist/$(call pkg_version,%)/debian/changelog: bld/changelog.tmpl | dist/$(call pkg_version,%)/debian
	sed "s,##DISTRIBUTIONS##,$* $(addprefix $*-,updates testing unstable),g" bld/changelog.tmpl > dist/$(call pkg_version,$*)/debian/changelog
	sed -i.bak "s,##VERSION_RELEASE##,$(call aug_version,,$*),g" dist/$(call pkg_version,$*)/debian/changelog && rm dist/$(call pkg_version,$*)/debian/changelog.bak

# N.B. This target will copy all files from the source to the dest. as one target
$(addprefix dist/$(call pkg_version,%)/debian/,$(debian_shared)): $(addprefix pkgsrc/deb/shared/debian/,$(debian_shared)) | dist/$(call pkg_version,%)/debian
	cp -Ra pkgsrc/deb/shared/debian/. dist/$(call pkg_version,$*)/debian/
	# next, copy specific package overwrites
	cp -Ra pkgsrc/deb/meta/dist/$*/debian/. dist/$(call pkg_version,$*)/debian/

dist/$(call file_version,%).orig.tar.gz: dist/$(call pkg_version,%)/debian/fs-horizon dist/$(call pkg_version,%)/debian/fs-bluehorizon dist/$(call pkg_version,%)/debian/changelog $(addprefix dist/$(call pkg_version,%)/debian/,$(debian_shared))
	for src in $(subproject); do \
		rsync -a --exclude=".git" $(PWD)/$$src dist/$(call pkg_version,$*)/; \
	done
	tar czf dist/$(call file_version,$*).orig.tar.gz -C dist/$(call pkg_version,$*) .

# also builds the bluehorizon package
$(bluehorizon_deb_packages):
dist/blue$(call pkg_version,%)_$(ARCH).deb:
$(horizon_deb_packages):
dist/$(call pkg_version,%)_$(ARCH).deb: dist/$(call file_version,%).orig.tar.gz
	@echo "Running Debian build in $*"
	cd dist/$(call pkg_version,$*) && \
		debuild -us -uc --lintian-opts --allow-root

$(meta): meta-%: bld/changelog.tmpl dist/$(call file_version,%).orig.tar.gz
	tools/meta-precheck $(CURDIR) "$(DOCKER_TAG_PREFIX)/$(VERSION)" $(subproject)
	@echo "================="
	@echo "Metadata created"
	@echo "================="
	@echo "Please inspect dist/$(call pkg_version,$*), the shared template file bld/changelog.tmpl, and VERSION. If accurate and if no other changes exist in the local copy, execute 'make publish-meta'. This will commit your local changes to the canonical upstream and tag dependent projects. The operation requires manual effort to undo so be sure you're ready before executing."

meta: $(meta)

package: $(package)

publish-meta-bld/%:
	@echo "+ Visiting publish-meta subproject $*"
	tools/git-tag 0 "$(CURDIR)/bld/$*" "$(DOCKER_TAG_PREFIX)/$(VERSION)"

publish-meta: $(addprefix publish-meta-bld/,$(subproject_names))
	git checkout -b horizon_$(VERSION)
	cp bld/changelog.tmpl pkgsrc/deb/meta/changelog.tmpl
	git add ./VERSION pkgsrc/deb/meta/changelog.tmpl
	git commit -m "updated package metadata to $(VERSION)"
	git push --set-upstream origin horizon_$(VERSION)

show-package:
	@echo $(package)

show-subproject:
	@echo $(subproject)

show-distribution:
	@echo $(addprefix dist/,$(distribution_names))

show-distribution-names:
	@echo $(distribution_names)

bld:
	mkdir -p bld

# TODO: consider making deps at this stage: that'd put all deps in the orig.tar.gz. This could be good for repeatable builds (we fetch from the internet all deps and wrap them in a source package), but it could be legally tenuous and there is still a chance of differences b/n .orig.tar.gzs between different arch's builds (b/c different machines run the builds and each fetches its own copy of those deps)
	#-@[ ! -e "bld/$*" ] && git clone ssh://git@github.com/open-horizon/$*.git "$(CURDIR)/bld/$*" && cd $(CURDIR)/bld/$* && $(MAKE) deps
# TODO: could add capability to build from specified branch instead of master (right now this is only supported by doing some of the build steps, monkeying with the local copy and then running the rest of the steps.

bld/%/.git/logs/HEAD: | bld
	@echo "fetching $*"
	git clone ssh://git@github.com/open-horizon/$*.git "$(CURDIR)/bld/$*"

bld/%/.git-gen-changelog: bld/%/.git/logs/HEAD | bld
	tools/git-gen-changelog "$(CURDIR)/bld/$*" "$(CURDIR)/pkgsrc/deb/meta/changelog.tmpl" "$(DOCKER_TAG_PREFIX)/$(VERSION)"

# make these "precious" so Make won't remove them
.PRECIOUS: dist/$(call file_version,%).orig.tar.gz bld/%/.git/logs/HEAD dist/$(call pkg_version,%)/debian $(addprefix dist/$(call pkg_version,%)/debian/,$(debian_shared) changelog fs-horizon fs-bluehorizon)

.PHONY: clean clean-src $(meta) mostlyclean publish-meta show-package show-subproject
