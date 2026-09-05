include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-fubotv-monitor
PKG_VERSION:=1.0.1
PKG_RELEASE:=1

LUCI_TITLE:=FuBoTv monitor reporter for ESP8266 weather clock
LUCI_DESCRIPTION:=Report router CPU, RAM utilization and CPU temperature to an \
	ESP8266 WiFi weather clock over HTTP, compatible with the stock Windows agent.
LUCI_DEPENDS:= \
	+luci-base \
	+curl \
	+ucode \
	+ucode-mod-fs \
	+ucode-mod-uci \
	+ucode-mod-ubus \
	+ucode-mod-uloop \
	+rpcd \
	+rpcd-mod-ucode
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# luci.mk 直接从源码树拷贝文件，Windows / 未设置可执行位的 checkout 会丢权限。
# 这里在 postinst 中显式补回，保证 ucode 脚本与 init.d 可被执行。
define Package/$(PKG_NAME)/postinst
#!/bin/sh
for f in \
	/usr/share/fubotv/lib.uc \
	/usr/share/fubotv/report.uc \
	/usr/share/rpcd/ucode/luci.fubotv \
	/etc/init.d/fubotv ; do
	[ -f "$${IPKG_INSTROOT}$$f" ] && chmod 0755 "$${IPKG_INSTROOT}$$f"
done
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
