package com.example.demo;

import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;

@Controller
public class HomeController {

    @GetMapping("/")
    public String home(Model model) {
        String deploymentColor = System.getenv().getOrDefault("APP_COLOR", "unknown");
        String deploymentTag = System.getenv().getOrDefault("APP_TAG", "n/a");
        model.addAttribute("message", "Welcome to Java Docker Demo");
        model.addAttribute("deploymentColor", deploymentColor);
        model.addAttribute("deploymentTag", deploymentTag);
        return "index";
    }
}
