print("Executing KissMP modScript...")
loadJsonMaterialsFile("art/shapes/kissmp_playermodels/main.materials.json")

load("kissplayers")
setExtensionUnloadMode("kissplayers", "manual")

load("vehiclemanager")
setExtensionUnloadMode("vehiclemanager", "manual")

load("kisstransform")
setExtensionUnloadMode("kisstransform", "manual")

load("kissui")
setExtensionUnloadMode("kissui", "manual")

load("kissmods")
setExtensionUnloadMode("kissmods", "manual")

load("kissrichpresence")
setExtensionUnloadMode("kissrichpresence", "manual")

load("network")
setExtensionUnloadMode("network", "manual")

load("kissconfig")
setExtensionUnloadMode("kissconfig", "manual")

load("kissvoicechat")
setExtensionUnloadMode("kissvoicechat", "manual")

--load("kissutils")
--registerCoreModule("kissutils")
