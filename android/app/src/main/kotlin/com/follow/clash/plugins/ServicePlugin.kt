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
        "acceptanceSnapshot" -> {
            if (BuildConfig.ENTOMA_NETWORK_ACCEPTANCE) result.success(GlobalState.getCurrentVPNPlugin()?.acceptanceSnapshot())
            else result.notImplemented()
        }
        "startVpn" -> {
            val data = call.argument<String>("data")
            val options = Gson().fromJson(data, VpnOptions::class.java)
            val plugin = GlobalState.getCurrentVPNPlugin()
            if (plugin == null) result.success(false)
            else { plugin.handleStart(options) { started -> result.success(started) }; Unit }
        }

        "stopVpn" -> {
            GlobalState.getCurrentVPNPlugin()?.handleStop()
            result.success(true)
        }

        "init" -> {
            GlobalState.getCurrentAppPlugin()
                ?.requestNotificationsPermission()
            GlobalState.initServiceEngine()
            result.success(true)
        }

        "destroy" -> {
            handleDestroy()
            result.success(true)
        }

        else -> {
            result.notImplemented()
        }
    }


    private fun handleDestroy() {
        GlobalState.destroyServiceEngine()
    }
}
