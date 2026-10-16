package com.follow.clash.plugins

import com.follow.clash.GlobalState
import com.follow.clash.BuildConfig
import com.follow.clash.models.VpnOptions
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel


data object ServicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var flutterMethodChannel: MethodChannel

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        flutterMethodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "service")
        flutterMethodChannel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        flutterMethodChannel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result): Unit = when (call.method) {
        "beginExit" -> {
            GlobalState.beginExit()
            result.success(true)
        }
        "cancelExit" -> result.success(GlobalState.cancelExit())
        "acceptanceSnapshot" -> {
            if (BuildConfig.ENTOMA_NETWORK_ACCEPTANCE) result.success(GlobalState.getCurrentVPNPlugin()?.acceptanceSnapshot())
            else result.notImplemented()
        }
        "startVpn" -> {
            val data = call.argument<String>("data")
            val options = Gson().fromJson(data, VpnOptions::class.java)
            val plugin = GlobalState.getCurrentVPNPlugin()
            if (plugin == null || GlobalState.isExitRequested) result.success(false)
            else { plugin.handleStart(options) { started -> result.success(started) }; Unit }
        }

        "stopVpn" -> {
            val plugin = GlobalState.getCurrentVPNPlugin()
            if (plugin == null) result.success(true)
            else plugin.handleStop { failure ->
                if (failure == null) result.success(true)
                else result.error("vpn_stop_failed", "VPN cleanup did not complete; retry stop", null)
            }
        }

        "init" -> {
            GlobalState.getCurrentAppPlugin()
                ?.requestNotificationsPermission()
            result.success(GlobalState.initServiceEngine())
        }

        "destroy" -> {
            result.success(GlobalState.destroyServiceEngine())
        }

        else -> {
            result.notImplemented()
        }
    }

}
